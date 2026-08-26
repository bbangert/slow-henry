defmodule RetrievalNode.MCP.ToolsTest do
  # async: false — mutates :git_mirror_root and shells out to real git.
  use RetrievalNode.DataCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias RetrievalNode.Embedding
  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Ingest.GitMirror
  alias RetrievalNode.MCP.Tools.{GetFile, Grep, ListRepos, RelatedCode, SemanticSearch}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:retrieval_node, :git_mirror_root)
    Application.put_env(:retrieval_node, :git_mirror_root, Path.join(root, "mirrors"))

    on_exit(fn ->
      Application.put_env(:retrieval_node, :git_mirror_root, prev)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  describe "list_repos" do
    test "returns active git + non-git sources with source_type and default_ref" do
      Repo.insert!(%Source{source_type: :git_repo, name: "acme/app", identifier: "file:///a"})
      Repo.insert!(%Source{source_type: :jira_project, name: "PROJ", identifier: "PROJ"})

      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "off",
        identifier: "file:///o",
        active: false
      })

      %{"repos" => repos} = ok(ListRepos, %{})
      names = Enum.map(repos, & &1["repo"])
      assert "acme/app" in names
      assert "PROJ" in names
      refute "off" in names

      git = Enum.find(repos, &(&1["repo"] == "acme/app"))
      assert git["source_type"] == "git_repo"
      assert git["default_ref"] == "HEAD"

      jira = Enum.find(repos, &(&1["repo"] == "PROJ"))
      assert jira["source_type"] == "jira_project"
      assert jira["default_ref"] == nil
    end
  end

  describe "get_file" do
    test "returns exact file bytes at HEAD", %{root: root} do
      seed_repo(root, "acme/app", [{"lib/foo.ex", "defmodule Foo, do: :ok\n"}])

      assert %{"repo" => "acme/app", "path" => "lib/foo.ex", "content" => content} =
               ok(GetFile, %{repo: "acme/app", path: "lib/foo.ex"})

      assert content == "defmodule Foo, do: :ok\n"
    end

    test "rejects a path-traversal attempt" do
      # No mirror needed — safe_path rejects before any git call.
      Repo.insert!(%Source{source_type: :git_repo, name: "acme/app", identifier: "file:///a"})

      assert err(GetFile, %{repo: "acme/app", path: "../../etc/passwd"}) =~ "path traversal"
    end

    test "unknown repo is an error" do
      assert err(GetFile, %{repo: "nope", path: "a.ex"}) =~ "repo not found"
    end

    test "a missing path or ref is a not-found error", %{root: root} do
      seed_repo(root, "acme/app", [{"a.ex", "x\n"}])

      assert err(GetFile, %{repo: "acme/app", path: "does/not/exist.ex"}) =~ "not found"
      assert err(GetFile, %{repo: "acme/app", path: "a.ex", ref: "nonexistent"}) =~ "not found"
    end
  end

  describe "grep" do
    test "returns {repo, path, line, text} matches for a pattern", %{root: root} do
      seed_repo(root, "acme/app", [
        {"a.py", "def alpha():\n    return 1\n"},
        {"b.py", "def beta():\n    return 2\n"}
      ])

      %{"matches" => matches} = ok(Grep, %{pattern: "alpha", repo: "acme/app"})

      assert [%{"repo" => "acme/app", "path" => "a.py", "line" => 1, "text" => text}] = matches
      assert text =~ "alpha"
    end

    test "unknown repo is an error" do
      assert err(Grep, %{pattern: "x", repo: "nope"}) =~ "repo not found"
    end

    test "a match-everything pattern is rejected (DoS guard)" do
      for p <- ["", ".", ".*"] do
        assert err(Grep, %{pattern: p}) =~ "too broad"
      end
    end

    test "an invalid regex surfaces as an error, not empty results", %{root: root} do
      seed_repo(root, "acme/app", [{"a.py", "x = 1\n"}])
      assert err(Grep, %{pattern: "[", repo: "acme/app"}) =~ "pattern"
    end

    test "caps a huge result set and flags it truncated", %{root: root} do
      # 6 files × 150 matching lines; git grep's -m caps each file at 100 → 600
      # matches, over the 500 aggregate cap.
      files = for i <- 1..6, do: {"f#{i}.txt", String.duplicate("match\n", 150)}
      seed_repo(root, "acme/big", files)

      %{"matches" => matches, "truncated" => truncated} =
        ok(Grep, %{pattern: "match", repo: "acme/big"})

      assert truncated == true
      assert length(matches) == 500
    end

    test "a within-cap result is not flagged truncated", %{root: root} do
      seed_repo(root, "acme/small", [{"a.py", "needle\n"}])
      %{"truncated" => truncated} = ok(Grep, %{pattern: "needle", repo: "acme/small"})
      assert truncated == false
    end

    test "repo-less grep aggregates across all indexed repos", %{root: root} do
      seed_repo(root, "acme/one", [{"a.py", "needle here\n"}])
      seed_repo(root, "acme/two", [{"b.py", "needle there\n"}])

      %{"matches" => matches} = ok(Grep, %{pattern: "needle"})
      repos = matches |> Enum.map(& &1["repo"]) |> Enum.uniq() |> Enum.sort()
      assert repos == ["acme/one", "acme/two"]
    end
  end

  describe "semantic_search" do
    test "returns ranked back-links (breadcrumb/score) and never content" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "acme/app", identifier: "file:///a"})

      insert_chunk(source, :git_repo, "authentication and login handling",
        repo: "acme/app",
        lang: "python",
        breadcrumb: "acme/app › auth.py › login"
      )

      %{"results" => [hit | _]} = ok(SemanticSearch, %{query: "authentication"})
      assert hit["breadcrumb"] =~ "login"
      assert hit["source_type"] == "git_repo"
      assert hit["score"] > 0
      refute Map.has_key?(hit, "content")
    end

    test "source filter narrows to a source_type" do
      git = Repo.insert!(%Source{source_type: :git_repo, name: "g", identifier: "file:///g"})
      insert_chunk(git, :git_repo, "widgetalpha one")

      jira = Repo.insert!(%Source{source_type: :jira_project, name: "j", identifier: "J"})
      insert_chunk(jira, :jira_project, "widgetalpha two")

      %{"results" => results} = ok(SemanticSearch, %{query: "widgetalpha", source: "jira"})
      assert results != []
      assert Enum.all?(results, &(&1["source_type"] == "jira_project"))
    end

    test "an unknown source is rejected" do
      assert err(SemanticSearch, %{query: "x", source: "bogus"}) =~ "unknown source"
    end

    test "repo filter narrows results and an unmatched query returns none" do
      a = Repo.insert!(%Source{source_type: :git_repo, name: "a", identifier: "file:///a"})
      b = Repo.insert!(%Source{source_type: :git_repo, name: "b", identifier: "file:///b"})
      insert_chunk(a, :git_repo, "flurbo accounting", repo: "a")
      insert_chunk(b, :git_repo, "flurbo billing", repo: "b")

      %{"results" => results} = ok(SemanticSearch, %{query: "flurbo", repo: "a"})
      assert results != []
      assert Enum.all?(results, &(&1["repo"] == "a"))

      # A filter that matches no candidate returns nothing (the dense side can't
      # backfill nearest-neighbours from outside the filtered candidate set).
      %{"results" => none} = ok(SemanticSearch, %{query: "flurbo", repo: "no-such-repo"})
      assert none == []
    end

    test "rerank: true carries fused_score alongside score; omitted does not" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "acme/rr", identifier: "file:///rr"})

      insert_chunk(source, :git_repo, "authentication and login handling",
        repo: "acme/rr",
        lang: "python",
        breadcrumb: "acme/rr › auth.py › login"
      )

      %{"results" => [hit | _]} = ok(SemanticSearch, %{query: "authentication", rerank: true})
      assert Map.has_key?(hit, "fused_score")
      assert is_float(hit["fused_score"])

      %{"results" => [hit | _]} = ok(SemanticSearch, %{query: "authentication"})
      refute Map.has_key?(hit, "fused_score")
    end

    test "graph: true surfaces a chunk reachable only via an entity mention; omitted does not" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "acme/graph", identifier: "file:///g"})

      entity =
        Repo.insert!(%Entity{
          source_id: source.id,
          language: "python",
          qualified_name: "PaymentProcessor.process_payment",
          kind: :function
        })

      # No embedding and content unrelated to the query — reachable, if at
      # all, only through the entity leg (mirrors HybridQueryTest's
      # graph-leg seeding trick).
      graph_only_chunk =
        Repo.insert!(%Chunk{
          source_id: source.id,
          source_type: :git_repo,
          repo: "acme/graph",
          chunk_key: "k-graph-#{System.unique_integer([:positive])}",
          content_hash: "h-graph-#{System.unique_integer([:positive])}",
          content: "totally unrelated filler about zebras",
          context_breadcrumb: "bc",
          metadata: %{},
          embedding: nil
        })

      Repo.insert!(%EntityMention{
        entity_id: entity.id,
        chunk_id: graph_only_chunk.id,
        kind: :definition
      })

      %{"results" => without_graph} = ok(SemanticSearch, %{query: "payment processing"})
      refute graph_only_chunk.id in Enum.map(without_graph, & &1["chunk_id"])

      %{"results" => with_graph} =
        ok(SemanticSearch, %{query: "payment processing", graph: true})

      assert graph_only_chunk.id in Enum.map(with_graph, & &1["chunk_id"])
    end
  end

  describe "related_code" do
    defp graph_entity(source, qualified_name, opts \\ []) do
      Repo.insert!(%Entity{
        source_id: source.id,
        language: Keyword.get(opts, :lang, "python"),
        qualified_name: qualified_name,
        kind: :function
      })
    end

    defp graph_chunk(source, path, repo) do
      Repo.insert!(%Chunk{
        source_id: source.id,
        source_type: :git_repo,
        repo: repo,
        chunk_key: "k-#{System.unique_integer([:positive])}",
        content_hash: "h-#{System.unique_integer([:positive])}",
        content: "def #{path}():\n    return 1\n",
        context_breadcrumb: path,
        metadata: %{"path" => path}
      })
    end

    defp graph_mention(entity, chunk, kind),
      do: Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: kind})

    defp graph_edge(source_entity, target_entity, kind, weight) do
      Repo.insert!(%EntityEdge{
        source_entity_id: source_entity.id,
        target_entity_id: target_entity.id,
        kind: kind,
        weight: weight
      })
    end

    test "definitions happy path returns the entity and its definition snippet" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "d", identifier: "file:///d"})
      entity = graph_entity(source, "PaymentProcessor.process")
      chunk = graph_chunk(source, "process.py", "acme/d")
      graph_mention(entity, chunk, :definition)

      assert %{"entities" => [found], "definitions" => [snippet]} =
               ok(RelatedCode, %{entity: "process"})

      assert found["qualified_name"] == "PaymentProcessor.process"
      assert found["kind"] == "function"
      assert found["entity_id"] == entity.id
      assert found["source_id"] == source.id
      assert snippet["repo"] == "acme/d"
      assert snippet["path"] == "process.py"
      # correlatable: the entity object and its definition snippet carry the
      # same entity_id, so a caller can tie a snippet back to its entity.
      assert snippet["entity_id"] == found["entity_id"]
    end

    test "callers with hops=2 returns transitive callers tagged with the right hop" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "c", identifier: "file:///c"})
      target = graph_entity(source, "target_fn")
      caller1 = graph_entity(source, "caller1_fn")
      caller2 = graph_entity(source, "caller2_fn")

      graph_edge(caller1, target, :calls, 3)
      graph_edge(caller2, caller1, :calls, 7)

      assert %{"entities" => entities} =
               ok(RelatedCode, %{entity: "target_fn", relation: "callers", hops: 2})

      by_name = Map.new(entities, &{&1["qualified_name"], &1})
      assert %{"weight" => 3, "hop" => 1, "entity_id" => caller1_id} = by_name["caller1_fn"]
      assert %{"weight" => 7, "hop" => 2, "entity_id" => caller2_id} = by_name["caller2_fn"]
      assert caller1_id == caller1.id
      assert caller2_id == caller2.id
    end

    test "an invalid relation is rejected with a listing of valid values" do
      assert err(RelatedCode, %{entity: "x", relation: "bogus"}) =~ "unknown relation"
    end

    test "invalid hops values (0 and 3) are rejected with an error" do
      for hops <- [0, 3] do
        assert err(RelatedCode, %{entity: "x", hops: hops}) =~ "invalid hops"
      end
    end

    test "an unmatched entity is a valid empty result, not an error" do
      assert %{"entities" => [], "note" => note} =
               ok(RelatedCode, %{entity: "NoSuchEntityAtAllZzz"})

      assert note =~ "no entity matched"
    end

    test "an oversized entity name is rejected before it ever reaches a query" do
      too_long = String.duplicate("a", 257)
      assert err(RelatedCode, %{entity: too_long}) =~ "too long"
    end

    test "entity: \"%\" does not walk the corpus — LIKE metacharacters are escaped" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "esc", identifier: "file:///esc"})

      _entity = graph_entity(source, "PaymentProcessor.process")

      assert %{"entities" => [], "note" => note} = ok(RelatedCode, %{entity: "%"})
      assert note =~ "no entity matched"
    end

    test "repo filter scopes resolution to entities mentioned in that repo" do
      source_a = Repo.insert!(%Source{source_type: :git_repo, name: "ra", identifier: "acme/ra"})
      source_b = Repo.insert!(%Source{source_type: :git_repo, name: "rb", identifier: "acme/rb"})

      entity_a = graph_entity(source_a, "shared_fn")
      entity_b = graph_entity(source_b, "shared_fn")

      chunk_a = graph_chunk(source_a, "a.py", "repo-a")
      chunk_b = graph_chunk(source_b, "b.py", "repo-b")

      graph_mention(entity_a, chunk_a, :definition)
      graph_mention(entity_b, chunk_b, :definition)

      assert %{"entities" => [found], "definitions" => [snippet]} =
               ok(RelatedCode, %{entity: "shared_fn", repo: "repo-a"})

      assert found["qualified_name"] == "shared_fn"
      assert found["entity_id"] == entity_a.id
      refute found["entity_id"] == entity_b.id
      assert snippet["repo"] == "repo-a"
      assert snippet["entity_id"] == found["entity_id"]
    end

    test "importers resolves via import mentions when no edge exists (file-level import)" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "imp", identifier: "file:///imp"})

      importer = graph_entity(source, "app_module")
      imported = graph_entity(source, "os")

      chunk = graph_chunk(source, "app.py", "acme/imp")
      graph_mention(importer, chunk, :definition)
      graph_mention(imported, chunk, :import)

      assert %{"entities" => [found]} =
               ok(RelatedCode, %{entity: "os", relation: "importers"})

      assert found["qualified_name"] == "app_module"
    end

    test "a matched entity with no traversal results carries a note explaining why" do
      source =
        Repo.insert!(%Source{source_type: :git_repo, name: "empty", identifier: "file:///e"})

      entity = graph_entity(source, "lonely_fn")
      chunk = graph_chunk(source, "lonely.py", "acme/empty")
      graph_mention(entity, chunk, :definition)

      assert %{"entities" => [], "definitions" => [], "note" => note} =
               ok(RelatedCode, %{entity: "lonely_fn", relation: "callers"})

      assert note =~ "no call edges"
    end

    test "lang filter scopes resolution to entities of that language" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "lg", identifier: "acme/lg"})

      python_entity = graph_entity(source, "shared_lang_fn", lang: "python")
      js_entity = graph_entity(source, "shared_lang_fn", lang: "javascript")

      python_chunk = graph_chunk(source, "a.py", "acme/lg")
      js_chunk = graph_chunk(source, "a.js", "acme/lg")

      graph_mention(python_entity, python_chunk, :definition)
      graph_mention(js_entity, js_chunk, :definition)

      assert %{"entities" => [found]} =
               ok(RelatedCode, %{entity: "shared_lang_fn", lang: "javascript"})

      assert found["qualified_name"] == "shared_lang_fn"
      assert found["language"] == "javascript"
    end
  end

  # --- helpers ---

  # Run a tool and decode a successful JSON payload (string-keyed).
  defp ok(mod, params) do
    assert {:reply, %Response{isError: false, content: [%{"text" => text}]}, _frame} =
             mod.execute(params, Frame.new())

    Jason.decode!(text)
  end

  # Run a tool and return the error message text.
  defp err(mod, params) do
    assert {:reply, %Response{isError: true, content: [%{"text" => msg}]}, _frame} =
             mod.execute(params, Frame.new())

    msg
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp seed_repo(root, name, files) do
    src = Path.join(root, "src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    git!(src, ["init", "-q"])
    git!(src, ["config", "user.email", "t@t"])
    git!(src, ["config", "user.name", "t"])

    Enum.each(files, fn {p, c} ->
      full = Path.join(src, p)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, c)
    end)

    git!(src, ["add", "-A"])
    git!(src, ["commit", "-qm", "c"])

    source =
      Repo.insert!(%Source{source_type: :git_repo, name: name, identifier: "file://" <> src})

    {:ok, _} = GitMirror.ensure_mirror(name, source.identifier)
    source
  end

  defp insert_chunk(source, type, content, opts \\ []) do
    Repo.insert!(
      Chunk.upsert_changeset(%Chunk{}, %{
        source_id: source.id,
        source_type: type,
        repo: opts[:repo],
        lang: opts[:lang],
        chunk_key: "k-#{System.unique_integer([:positive])}",
        content_hash: "h-#{System.unique_integer([:positive])}",
        content: content,
        context_breadcrumb: opts[:breadcrumb] || "bc",
        embedding: Embedding.embed(content)
      })
    )
  end
end
