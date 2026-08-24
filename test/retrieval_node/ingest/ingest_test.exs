defmodule RetrievalNode.IngestTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # the application tree starts (same reason as Ingest.PipelineTest/GraphTest).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Graph.Entity
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{PendingChunk, Source, SyncState}

  describe "force_full_resync_git_sources/0" do
    test "clears an existing watermark and enqueues RepoSync for each active git source" do
      git =
        Repo.insert!(%Source{source_type: :git_repo, name: "g1", identifier: "file:///g1"})

      Repo.insert!(%SyncState{source_id: git.id, cursor: %{"last_sha" => "deadbeef"}})

      assert {:ok, 1} = Ingest.force_full_resync_git_sources()

      state = Repo.get_by!(SyncState, source_id: git.id)
      assert state.cursor == %{}

      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id})
    end

    test "creates a sync_state when one doesn't exist yet" do
      git =
        Repo.insert!(%Source{source_type: :git_repo, name: "g2", identifier: "file:///g2"})

      refute Repo.get_by(SyncState, source_id: git.id)

      assert {:ok, 1} = Ingest.force_full_resync_git_sources()

      state = Repo.get_by!(SyncState, source_id: git.id)
      assert state.cursor == %{}
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id})
    end

    test "leaves inactive git sources and non-git sources untouched" do
      active =
        Repo.insert!(%Source{source_type: :git_repo, name: "active", identifier: "file:///a"})

      inactive =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "inactive",
          identifier: "file:///i",
          active: false
        })

      Repo.insert!(%SyncState{source_id: inactive.id, cursor: %{"last_sha" => "keepme"}})

      jira =
        Repo.insert!(%Source{source_type: :jira_project, name: "j", identifier: "PROJ"})

      Repo.insert!(%SyncState{source_id: jira.id, cursor: %{"resolutiondate_watermark" => "x"}})

      drive =
        Repo.insert!(%Source{source_type: :drive_folder, name: "d", identifier: "root"})

      assert {:ok, 1} = Ingest.force_full_resync_git_sources()

      assert_enqueued(worker: RepoSync, args: %{"source_id" => active.id})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => inactive.id})

      # inactive git source's cursor is untouched
      inactive_state = Repo.get_by!(SyncState, source_id: inactive.id)
      assert inactive_state.cursor == %{"last_sha" => "keepme"}

      # jira/drive sources got no RepoSync job and no cursor mutation
      refute_enqueued(worker: RepoSync, args: %{"source_id" => jira.id})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => drive.id})
      jira_state = Repo.get_by!(SyncState, source_id: jira.id)
      assert jira_state.cursor == %{"resolutiondate_watermark" => "x"}
      refute Repo.get_by(SyncState, source_id: drive.id)
    end
  end

  describe "backfill_status/0" do
    test "returns pending_chunks, oban_jobs, and graph counts" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "g", identifier: "file:///g"})

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

      status = Ingest.backfill_status()

      assert %{pending_chunks: pending, oban_jobs: oban_jobs, graph: graph} = status

      assert pending["raw"] == 1

      assert oban_jobs["sync"]["available"] == 1

      assert graph.entities == 1
      assert graph.entity_mentions == 0
      assert graph.entity_edges == 0
      assert graph.chunks == 0
    end
  end
end
