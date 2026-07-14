defmodule RetrievalNode.MCP.ToolsTest do
  # async: false — mutates :git_mirror_root and shells out to real git.
  use RetrievalNode.DataCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias RetrievalNode.Embedding
  alias RetrievalNode.Ingest.GitMirror
  alias RetrievalNode.MCP.Tools.{GetFile, Grep, ListRepos, SemanticSearch}
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
