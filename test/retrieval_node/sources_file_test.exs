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

    test "re-activating a deny-policy source updates it but queues no sync" do
      denied =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "snitun",
          identifier: @url_b,
          active: false,
          policy: :deny
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("snitun", @url_b)]})

      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{active: true, policy: :deny} = Repo.get!(Source, denied.id)
      refute_enqueued(worker: RepoSync)
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

  describe "config and slugs" do
    test "an unchanged entry leaves a source's config intact" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr",
          identifier: @url_a,
          config: %{"mirror_slug" => "adr-old", "other" => 1}
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:unchanged, _}]} = SourcesFile.plan(entries)
      assert {:ok, _} = SourcesFile.apply(entries)
      assert %{config: %{"mirror_slug" => "adr-old", "other" => 1}} = Repo.get!(Source, s.id)
    end

    test "renaming pins the old slug, keeping other config" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr-old",
          identifier: @url_a,
          config: %{"other" => 1}
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})
      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr", config: %{"mirror_slug" => "adr-old", "other" => 1}} =
               Repo.get!(Source, s.id)
    end

    test "renaming leaves an existing mirror_slug alone" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr-old",
          identifier: @url_a,
          config: %{"mirror_slug" => "pinned"}
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})
      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr", config: %{"mirror_slug" => "pinned"}} = Repo.get!(Source, s.id)
    end

    test "an add that reuses an inactive source's slug is rejected" do
      source!("adr", @url_a, false)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_b)]})

      assert {:error, msg} = SourcesFile.plan(entries)
      assert msg =~ ~s|name "adr" is already the mirror slug of #{@url_a} (inactive)|
      assert {:error, ^msg} = SourcesFile.apply(entries)
      refute Repo.get_by(Source, identifier: @url_b)
    end

    test "changing a url while keeping the name is rejected" do
      source!("adr", @url_a)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_b)]})

      assert {:error, msg} = SourcesFile.plan(entries)
      assert msg =~ "#{@url_a} (active)"
      assert %{active: true} = Repo.get_by!(Source, identifier: @url_a)
    end

    test "an add that reuses a renamed source's pinned slug is rejected" do
      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "adr",
        identifier: @url_a,
        config: %{"mirror_slug" => "adr-old"}
      })

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a), git("adr-old", @url_b)]})

      assert {:error, "name \"adr-old\" is already the mirror slug of " <> _} =
               SourcesFile.plan(entries)
    end
  end

  describe "Mix.Tasks.Rn.Sources.parse_args!/1" do
    alias Mix.Tasks.Rn.Sources, as: Task

    test "accepts known switches" do
      assert [dry_run: true, file: "x.toml"] = Task.parse_args!(["--dry-run", "--file", "x.toml"])
    end

    test "rejects invalid switches, missing values and positional args" do
      assert_raise Mix.Error, ~r/invalid option.*--dryrun/, fn ->
        Task.parse_args!(["--dryrun"])
      end

      assert_raise Mix.Error, ~r/invalid option.*--file/, fn -> Task.parse_args!(["--file"]) end

      assert_raise Mix.Error, ~r/unexpected argument.*extra/, fn ->
        Task.parse_args!(["extra"])
      end
    end
  end

  defp strip({:deactivate, s}), do: {:deactivate, %{id: s.id}}
  defp strip(other), do: other
end
