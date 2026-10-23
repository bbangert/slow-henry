defmodule RetrievalNode.SourcesFileTest do
  use RetrievalNode.DataCase, async: true
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source
  alias RetrievalNode.SourcesFile

  @url_a "https://github.com/my-org/adr.git"
  @url_b "https://github.com/my-org/other.git"

  defp git(name, url, extra \\ %{}), do: Map.merge(%{"name" => name, "url" => url}, extra)

  defp source!(name, url, active \\ true) do
    Repo.insert!(%Source{source_type: :git_repo, name: name, identifier: url, active: active})
  end

  describe "load/1 and parse/1" do
    @tag :tmp_dir
    test "reads [[git]] tables, active defaults to true", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")

      File.write!(path, """
      [[git]]
      name = "adr"
      url = "#{@url_a}"

      [[git]]
      name = "snitun"
      url = "#{@url_b}"
      active = false
      """)

      assert {:ok,
              [
                %{source_type: :git_repo, name: "adr", identifier: @url_a, active: true},
                %{source_type: :git_repo, name: "snitun", identifier: @url_b, active: false}
              ]} = SourcesFile.load(path)
    end

    test "the committed sources.example.toml is valid" do
      assert {:ok, [_ | _]} = SourcesFile.load("sources.example.toml")
    end

    test "an empty document means no git sources" do
      assert {:ok, []} = SourcesFile.parse(%{})
    end

    test "reports a missing file" do
      assert {:error, "cannot read /nope/sources.toml" <> _} =
               SourcesFile.load("/nope/sources.toml")
    end

    test "rejects invalid entries with their position" do
      assert {:error, "[[git]] #1: `name` and `url` are required strings"} =
               SourcesFile.parse(%{"git" => [%{"name" => "adr"}]})

      assert {:error, "[[git]] #2: invalid name \"../etc\""} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("../etc", @url_b)]})

      assert {:error, "[[git]] #1: invalid url \"ext::sh -c id\""} =
               SourcesFile.parse(%{"git" => [git("adr", "ext::sh -c id")]})

      assert {:error, "[[git]] #1: unknown key(s) branch"} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"branch" => "main"})]})

      assert {:error, "[[git]] #1: `active` must be true or false"} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"active" => "no"})]})
    end

    test "rejects duplicate names and urls" do
      assert {:error, "duplicate name \"adr\""} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("adr", @url_b)]})

      assert {:error, "duplicate url " <> _} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("other", @url_a)]})
    end
  end

  describe "apply/1" do
    test "adds new sources and queues their first sync" do
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:add, _}]} = SourcesFile.apply(entries)

      source = Repo.get_by!(Source, identifier: @url_a)
      assert %{name: "adr", active: true, source_type: :git_repo} = source
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id})
    end

    test "is idempotent: a second apply changes nothing" do
      existing = source!("adr", @url_a)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:unchanged, %{id: id}}]} = SourcesFile.apply(entries)
      assert id == existing.id
      refute_enqueued(worker: RepoSync)
    end

    test "deactivates sources missing from the file without deleting them" do
      kept = source!("adr", @url_a)
      gone = source!("snitun", @url_b)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, changes} = SourcesFile.apply(entries)
      assert {:deactivate, %{id: gone.id}} in Enum.map(changes, &strip/1)

      assert %{active: false} = Repo.get!(Source, gone.id)
      assert %{active: true} = Repo.get!(Source, kept.id)
    end

    test "re-activating a source queues a sync; a rename does not" do
      inactive = source!("snitun", @url_b, false)
      renamed = source!("adr-old", @url_a)

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a), git("snitun", @url_b)]})

      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr"} = Repo.get!(Source, renamed.id)
      assert %{active: true} = Repo.get!(Source, inactive.id)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => inactive.id})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => renamed.id})
    end

    test "leaves non-git sources alone" do
      jira =
        Repo.insert!(%Source{
          source_type: :jira_project,
          name: "Jira: CLOUD",
          identifier: "CLOUD"
        })

      assert {:ok, []} = SourcesFile.apply([])
      assert %{active: true} = Repo.get!(Source, jira.id)
    end
  end

  defp strip({:deactivate, s}), do: {:deactivate, %{id: s.id}}
  defp strip(other), do: other
end
