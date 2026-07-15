defmodule Mix.Tasks.Rn.SeedTest do
  # Only the pure/Ecto upsert helper — the rest of the task shells out to
  # Mix.Task.run("app.start") and Oban.insert against a live Oban instance,
  # which is not exercised here (see rn.seed.ex moduledoc for the manual
  # verification run).
  use RetrievalNode.DataCase, async: true

  alias Mix.Tasks.Rn.Seed
  alias RetrievalNode.Retrieval.Source

  describe "upsert_source/1" do
    test "creates a source, then a rerun with the same [:source_type, :identifier] updates it in place" do
      attrs = %{source_type: :git_repo, name: "acme/app", identifier: "file:///tmp/acme.git"}

      assert {:ok, first} = Seed.upsert_source(attrs)
      assert first.name == "acme/app"

      assert {:ok, second} = Seed.upsert_source(Map.put(attrs, :name, "acme/app-renamed"))

      assert second.id == first.id
      assert second.name == "acme/app-renamed"
      assert second.identifier == first.identifier
      assert Repo.aggregate(Source, :count, :id) == 1
    end

    test "different identifiers create distinct sources" do
      assert {:ok, git} =
               Seed.upsert_source(%{
                 source_type: :git_repo,
                 name: "repo-a",
                 identifier: "file:///tmp/a.git"
               })

      assert {:ok, jira} =
               Seed.upsert_source(%{
                 source_type: :jira_project,
                 name: "Jira: PROJ",
                 identifier: "PROJ"
               })

      assert git.id != jira.id
      assert Repo.aggregate(Source, :count, :id) == 2
    end
  end
end
