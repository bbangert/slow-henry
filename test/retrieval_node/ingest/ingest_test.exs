defmodule RetrievalNode.IngestTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # the application tree starts (same reason as Ingest.PipelineTest/GraphTest).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Graph.Entity
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{FileVersion, PendingChunk, Source, SyncState}

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

  describe "force_full_resync_git_sources/1 (targeted)" do
    test "clears only the named source's cursor and enqueues only its RepoSync job" do
      target =
        Repo.insert!(%Source{source_type: :git_repo, name: "target", identifier: "file:///t"})

      other =
        Repo.insert!(%Source{source_type: :git_repo, name: "other", identifier: "file:///o"})

      Repo.insert!(%SyncState{source_id: target.id, cursor: %{"last_sha" => "aaa"}})
      Repo.insert!(%SyncState{source_id: other.id, cursor: %{"last_sha" => "bbb"}})

      assert {:ok, 1} = Ingest.force_full_resync_git_sources(["target"])

      target_state = Repo.get_by!(SyncState, source_id: target.id)
      assert target_state.cursor == %{}

      other_state = Repo.get_by!(SyncState, source_id: other.id)
      assert other_state.cursor == %{"last_sha" => "bbb"}

      assert_enqueued(worker: RepoSync, args: %{"source_id" => target.id})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => other.id})
    end

    test "matches on identifier as well as name" do
      target =
        Repo.insert!(%Source{source_type: :git_repo, name: "target", identifier: "file:///t"})

      assert {:ok, 1} = Ingest.force_full_resync_git_sources(["file:///t"])
      assert_enqueued(worker: RepoSync, args: %{"source_id" => target.id})
    end

    test "an unknown name is rejected — nothing is cleared or enqueued" do
      known =
        Repo.insert!(%Source{source_type: :git_repo, name: "known", identifier: "file:///k"})

      Repo.insert!(%SyncState{source_id: known.id, cursor: %{"last_sha" => "keep"}})

      assert {:error, {:unknown_sources, ["nope"]}} =
               Ingest.force_full_resync_git_sources(["known", "nope"])

      state = Repo.get_by!(SyncState, source_id: known.id)
      assert state.cursor == %{"last_sha" => "keep"}
      refute_enqueued(worker: RepoSync, args: %{"source_id" => known.id})
    end

    test ":all behaves exactly like the arity-0 function" do
      git =
        Repo.insert!(%Source{source_type: :git_repo, name: "g", identifier: "file:///g"})

      assert {:ok, 1} = Ingest.force_full_resync_git_sources(:all)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id})
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

  describe "claim_file_version/4" do
    setup do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
      %{source: source}
    end

    test "first claim for a file inserts the row and returns :claimed", %{source: source} do
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "app.py", 1)

      assert %FileVersion{generation: 1} =
               Repo.get_by!(FileVersion, source_id: source.id, identity: "app.py")
    end

    test "a strictly newer generation is :claimed and updates the persisted row", %{
      source: source
    } do
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "app.py", 1)
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "app.py", 2)

      assert %FileVersion{generation: 2} =
               Repo.get_by!(FileVersion, source_id: source.id, identity: "app.py")
    end

    test "an older generation is :stale and leaves the persisted row untouched", %{
      source: source
    } do
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "app.py", 5)
      assert :stale = Ingest.claim_file_version(Repo, source.id, "app.py", 3)

      assert %FileVersion{generation: 5} =
               Repo.get_by!(FileVersion, source_id: source.id, identity: "app.py")
    end

    test "an equal generation (a same-version retry after commit) is :stale — a clean no-op", %{
      source: source
    } do
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "app.py", 4)
      assert :stale = Ingest.claim_file_version(Repo, source.id, "app.py", 4)

      assert %FileVersion{generation: 4} =
               Repo.get_by!(FileVersion, source_id: source.id, identity: "app.py")
    end

    test "different files under the same source claim independently", %{source: source} do
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "a.py", 1)
      assert :claimed = Ingest.claim_file_version(Repo, source.id, "b.py", 1)

      assert Repo.aggregate(FileVersion, :count, :id) == 2
    end

    test "a claim with a ~5,000-byte identity succeeds — the failure this replaces", %{
      source: source
    } do
      long_identity = "src/" <> String.duplicate("very-long-directory-name/", 190) <> "file.py"
      assert byte_size(long_identity) > 4_500

      assert :claimed = Ingest.claim_file_version(Repo, source.id, long_identity, 1)

      assert %FileVersion{generation: 1} =
               Repo.get_by!(FileVersion, source_id: source.id, identity: long_identity)
    end
  end

  describe "identity_hash/1" do
    test "matches the SQL backfill's encoding for an ASCII identity" do
      assert_identity_hash_matches_sql("src/app.py")
    end

    test "matches the SQL backfill's encoding for a non-ASCII identity" do
      assert_identity_hash_matches_sql("docs/résumé-日本語.md")
    end

    defp assert_identity_hash_matches_sql(identity) do
      %Postgrex.Result{rows: [[sql_hash]]} =
        Repo.query!("SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex')", [identity])

      assert Ingest.identity_hash(identity) == sql_hash
    end
  end
end
