defmodule RetrievalNode.MCP.ToolsTest do
  # async: false — mutates :git_mirror_root and shells out to real git.
  use RetrievalNode.DataCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias RetrievalNode.Embedding
  alias RetrievalNode.Graph
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
  end

  describe "related_code" do
    test "definitions (default) returns the entity and its definition snippet" do
      source = graph_source("d")

      [chunk] =
        index_graph(source, [
          {graph_chunk(source, "process.py", "def process(): pass"),
           [def_("PaymentProcessor.process")], []}
        ])

      assert %{"entities" => [found], "definitions" => [snippet]} =
               ok(RelatedCode, %{entity: "process"})

      assert found["qualified_name"] == "PaymentProcessor.process"
      assert found["kind"] == "function"
      assert found["language"] == "python"
      assert found["source_id"] == source.id
      assert snippet["repo"] == source.identifier
      assert snippet["path"] == "process.py"
      assert snippet["snippet"] == chunk.content
      # the snippet carries the same entity_id so a caller can tie it back
      assert snippet["entity_id"] == found["entity_id"]
    end

    test "callers with hops=2 returns transitive callers tagged with the right hop" do
      source = graph_source("c")

      index_graph(source, [
        {graph_chunk(source, "a.py", "x"),
         [def_("target_fn"), def_("caller1_fn"), def_("caller2_fn")],
         List.duplicate(call("target_fn", "caller1_fn"), 3) ++
           List.duplicate(call("caller1_fn", "caller2_fn"), 7)}
      ])

      assert %{"entities" => entities} =
               ok(RelatedCode, %{entity: "target_fn", relation: "callers", hops: 2})

      by_name = Map.new(entities, &{&1["qualified_name"], &1})
      assert %{"weight" => 3, "hop" => 1} = by_name["caller1_fn"]
      assert %{"weight" => 7, "hop" => 2} = by_name["caller2_fn"]
    end

    test "importers resolves a file-level import (no edge exists)" do
      source = graph_source("imp")

      index_graph(source, [
        {graph_chunk(source, "app.py", "import os"), [def_("app_module")], [import_("os")]}
      ])

      assert %{"entities" => [found]} = ok(RelatedCode, %{entity: "os", relation: "importers"})
      assert found["qualified_name"] == "app_module"

      assert %{"entities" => [imported]} =
               ok(RelatedCode, %{entity: "app_module", relation: "imports"})

      assert imported["qualified_name"] == "os"
    end

    test "an invalid relation is rejected with a listing of valid values" do
      msg = err(RelatedCode, %{entity: "x", relation: "bogus"})
      assert msg =~ "unknown relation"
      assert msg =~ "callers"
    end

    test "invalid hops values are rejected with an error" do
      for hops <- [0, 3, -1] do
        assert err(RelatedCode, %{entity: "x", hops: hops}) =~ "invalid hops"
      end
    end

    test "blank, oversized, and non-string arguments are rejected before any query" do
      assert err(RelatedCode, %{entity: ""}) =~ "entity must not be blank"
      assert err(RelatedCode, %{entity: "   "}) =~ "entity must not be blank"
      assert err(RelatedCode, %{entity: String.duplicate("a", 257)}) =~ "entity too long"
      assert err(RelatedCode, %{entity: "x", repo: ""}) =~ "repo must not be blank"
      assert err(RelatedCode, %{entity: "x", lang: String.duplicate("a", 257)}) =~ "lang too long"
      assert err(RelatedCode, %{entity: "a\0b"}) =~ "invalid entity"
      assert err(RelatedCode, %{entity: 5}) =~ "entity must be a string"
    end

    test "an unmatched entity is a valid empty result, not an error" do
      assert %{"entities" => [], "note" => note} =
               ok(RelatedCode, %{entity: "NoSuchEntityAtAllZzz"})

      assert note =~ "no entity matched"
    end

    test "entity: \"%\" does not walk the corpus — LIKE metacharacters are escaped" do
      source = graph_source("esc")

      index_graph(source, [
        {graph_chunk(source, "a.py", "x"), [def_("PaymentProcessor.process")], []}
      ])

      assert %{"entities" => [], "note" => note} = ok(RelatedCode, %{entity: "%"})
      assert note =~ "no entity matched"
    end

    test "repo filter scopes resolution to entities mentioned in that repo" do
      source_a = graph_source("ra")
      source_b = graph_source("rb")

      index_graph(source_a, [{graph_chunk(source_a, "a.py", "a"), [def_("shared_fn")], []}])
      index_graph(source_b, [{graph_chunk(source_b, "b.py", "b"), [def_("shared_fn")], []}])

      assert %{"entities" => [found], "definitions" => [snippet]} =
               ok(RelatedCode, %{entity: "shared_fn", repo: source_a.identifier})

      assert found["source_id"] == source_a.id
      assert snippet["repo"] == source_a.identifier
    end

    test "a matched entity with no traversal results carries a note explaining why" do
      source = graph_source("empty")

      index_graph(source, [{graph_chunk(source, "l.py", "x"), [def_("lonely_fn")], []}])

      assert %{"entities" => [], "definitions" => [], "note" => note} =
               ok(RelatedCode, %{entity: "lonely_fn", relation: "callers"})

      assert note =~ "no call edges"

      assert %{"note" => import_note} =
               ok(RelatedCode, %{entity: "lonely_fn", relation: "importers"})

      assert import_note =~ "no import mentions"
    end

    test "result sizes stay bounded: entities capped at 50, snippets at 50 even for 60 matches" do
      source = graph_source("big")
      callers = for n <- 1..60, do: def_("caller_#{n}")
      refs = for n <- 1..60, do: call("hub_fn", "caller_#{n}")

      index_graph(source, [
        {graph_chunk(source, "hub.py", "x"), [def_("hub_fn") | callers], refs}
      ])

      assert %{"entities" => entities, "definitions" => defs} =
               ok(RelatedCode, %{entity: "hub_fn", relation: "callers"})

      assert length(entities) == 50
      assert length(defs) <= 50

      assert %{"entities" => matched} = ok(RelatedCode, %{entity: "caller_"})
      assert length(matched) <= 50
    end
  end

  # --- graph helpers ---

  defp graph_source(tag) do
    Repo.insert!(%Source{
      source_type: :git_repo,
      name: "acme/#{tag}",
      identifier: "acme/#{tag}-#{System.unique_integer([:positive])}"
    })
  end

  defp graph_chunk(source, path, content, opts \\ []) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      repo: source.identifier,
      lang: Keyword.get(opts, :lang, "python"),
      chunk_key: "k-#{System.unique_integer([:positive])}",
      content_hash: "h-#{System.unique_integer([:positive])}",
      content: content,
      context_breadcrumb: path,
      metadata: %{"path" => path}
    })
  end

  defp def_(name), do: %{qualified_name: name, kind: :function, line: 1}
  defp call(name, from), do: %{name: name, kind: :call, from: from, line: 2}
  defp import_(name), do: %{name: name, kind: :import, from: nil, line: 1}

  # Writes graph rows through the real Graph.upsert_from_staged/3 so entities,
  # mentions and edges have exactly the shape ingest produces. Entries are
  # {chunk, entities, references}; returns the chunks.
  defp index_graph(source, entries) do
    rows =
      for {chunk, entities, references} <- entries do
        %{
          source_id: source.id,
          lang: chunk.lang || "python",
          chunk_key: chunk.chunk_key,
          natural_key: "repo:#{source.identifier}:#{chunk.metadata["path"]}",
          metadata: chunk.metadata,
          graph: %{entities: entities, references: references}
        }
      end

    ids = Map.new(entries, fn {chunk, _, _} -> {chunk.chunk_key, chunk.id} end)
    {:ok, _} = Graph.upsert_from_staged(Repo, rows, ids)
    Enum.map(entries, &elem(&1, 0))
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
