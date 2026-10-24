defmodule RetrievalNode.IngestTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # the application tree starts.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Graph.Entity
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{PendingChunk, Source, SyncState}

  defp git_source(name, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Source{source_type: :git_repo, name: name, identifier: "file:///#{name}"},
        attrs
      )
    )
  end

  describe "force_full_resync_git_sources/0" do
    test "leaves the cursor untouched and enqueues a full: true RepoSync per syncable git source" do
      git = git_source("g1")
      Repo.insert!(%SyncState{source_id: git.id, cursor: %{"last_sha" => "deadbeef"}})

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources()

      assert Repo.get_by!(SyncState, source_id: git.id).cursor == %{"last_sha" => "deadbeef"}
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id, "full" => true})
    end

    test "works when no sync_state exists yet" do
      git = git_source("g2")

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources()

      refute Repo.get_by(SyncState, source_id: git.id)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id, "full" => true})
    end

    test "skips inactive, denied and non-git sources" do
      active = git_source("active")
      inactive = git_source("inactive", %{active: false})
      denied = git_source("denied", %{policy: :deny})
      jira = Repo.insert!(%Source{source_type: :jira_project, name: "j", identifier: "PROJ"})
      drive = Repo.insert!(%Source{source_type: :drive_folder, name: "d", identifier: "root"})

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources()

      assert_enqueued(worker: RepoSync, args: %{"source_id" => active.id, "full" => true})

      for s <- [inactive, denied, jira, drive] do
        refute_enqueued(worker: RepoSync, args: %{"source_id" => s.id})
      end
    end

    test "no existing job -> enqueued" do
      git = git_source("fresh")

      assert {:ok, %{enqueued: 1, upgraded: 0, busy: []}} = Ingest.force_full_resync_git_sources()
      assert [%{args: %{"full" => true}}] = all_enqueued(worker: RepoSync)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id, "full" => true})
    end

    test "a waiting plain sync is upgraded in place to a full one" do
      git = git_source("waiting")
      {:ok, plain} = Oban.insert(RepoSync.new(%{"source_id" => git.id}))
      assert plain.state == "available"

      assert {:ok, %{enqueued: 0, upgraded: 1, busy: []}} = Ingest.force_full_resync_git_sources()

      assert [job] =
               Repo.all(
                 from j in Oban.Job, where: j.worker == "RetrievalNode.Ingest.Workers.RepoSync"
               )

      assert job.id == plain.id
      assert job.args == %{"source_id" => git.id, "full" => true}
    end

    test "an executing plain sync is reported busy and no second job is created" do
      git = git_source("running")
      {:ok, plain} = Oban.insert(RepoSync.new(%{"source_id" => git.id}))
      plain |> Ecto.Changeset.change(state: "executing") |> Repo.update!()

      assert {:ok, %{enqueued: 0, upgraded: 0, busy: [busy]}} =
               Ingest.force_full_resync_git_sources()

      assert busy.id == git.id

      assert [job] =
               Repo.all(
                 from j in Oban.Job, where: j.worker == "RetrievalNode.Ingest.Workers.RepoSync"
               )

      assert job.id == plain.id
      assert job.args == %{"source_id" => git.id}
    end
  end

  describe "force_full_resync_git_sources/1 (targeted)" do
    test "enqueues only the named source" do
      target = git_source("target")
      other = git_source("other")

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources(["target"])

      assert_enqueued(worker: RepoSync, args: %{"source_id" => target.id, "full" => true})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => other.id})
    end

    test "matches on identifier as well as name" do
      target = git_source("target")

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources(["file:///target"])
      assert_enqueued(worker: RepoSync, args: %{"source_id" => target.id, "full" => true})
    end

    test "an unknown or non-syncable name is rejected and nothing is enqueued" do
      known = git_source("known")
      git_source("inactive", %{active: false})

      assert {:error, {:unknown_sources, ["nope", "inactive"]}} =
               Ingest.force_full_resync_git_sources(["known", "nope", "inactive"])

      refute_enqueued(worker: RepoSync, args: %{"source_id" => known.id})
    end

    test ":all behaves like the arity-0 function" do
      git = git_source("g")

      assert {:ok, %{enqueued: 1}} = Ingest.force_full_resync_git_sources(:all)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id, "full" => true})
    end
  end

  describe "backfill_status/0" do
    test "returns pending_chunks, oban_jobs, and graph counts" do
      source = git_source("g")

      Repo.insert!(%PendingChunk{
        status: "raw",
        source: "git",
        source_id: source.id,
        source_type: "git_repo",
        natural_key: "repo:#{source.id}:a.py",
        content_hash: "h1",
        raw_content: "def a(): pass"
      })

      Repo.insert!(%Entity{
        source_id: source.id,
        language: "python",
        qualified_name: "a",
        kind: :function
      })

      {:ok, _job} = Oban.insert(RepoSync.new(%{"source_id" => source.id}))

      assert %{
               pending_chunks: %{"raw" => 1},
               oban_jobs: %{"sync" => %{"available" => 1}},
               graph: %{entities: 1, entity_mentions: 0, entity_edges: 0, chunks: 0},
               failed_files: 0,
               owners: owners
             } = Ingest.backfill_status()

      assert is_integer(owners)
    end
  end
end
