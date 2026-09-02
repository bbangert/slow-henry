defmodule RetrievalNode.Ingest.SourcesTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.{Drive, Jira}

  alias RetrievalNode.Ingest.Workers.{
    ChunkFiles,
    DriveSync,
    EmbedBatch,
    JiraSync,
    RepoSync,
    SyncScheduler,
    UpsertChunks
  }

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, FileVersion, PendingChunk, Source, SyncState}

  describe "Jira client (pure)" do
    test "build_jql adds a resolutiondate watermark clause when present" do
      assert Jira.build_jql("PROJ", nil) =~ "project = \"PROJ\""
      refute Jira.build_jql("PROJ", nil) =~ "resolutiondate >="
      assert Jira.build_jql("PROJ", "2026-01-01") =~ "resolutiondate >= \"2026-01-01\""
    end

    test "parse_issues extracts summary + ADF description text" do
      body = %{
        "issues" => [
          %{
            "key" => "PROJ-1",
            "fields" => %{
              "summary" => "Fix the bug",
              "resolutiondate" => "2026-02-01T00:00:00.000+0000",
              "description" => %{
                "content" => [%{"content" => [%{"type" => "text", "text" => "root cause was X"}]}]
              }
            }
          }
        ]
      }

      assert [issue] = Jira.parse_issues(body)
      assert issue.key == "PROJ-1"
      assert issue.text =~ "Fix the bug"
      assert issue.text =~ "root cause was X"
    end
  end

  describe "Drive client (pure)" do
    test "parse_changes splits changed Docs from removed files and reads the cursor" do
      body = %{
        "newStartPageToken" => "tok-2",
        "changes" => [
          %{
            "fileId" => "d1",
            "file" => %{
              "id" => "d1",
              "name" => "Doc A",
              "mimeType" => "application/vnd.google-apps.document"
            }
          },
          %{"fileId" => "d2", "removed" => true}
        ]
      }

      assert %{changed: [doc], removed: ["d2"], cursor: "tok-2"} = Drive.parse_changes(body)
      assert doc.doc_id == "d1"
      assert doc.name == "Doc A"
    end
  end

  describe "SyncScheduler" do
    setup do
      :ok
    end

    test "fans out one sync job per active, allow-policy source of the kind" do
      git = Repo.insert!(%Source{source_type: :git_repo, name: "g", identifier: "file:///g"})

      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "inactive",
        identifier: "file:///x",
        active: false
      })

      Repo.insert!(%Source{source_type: :jira_project, name: "j", identifier: "PROJ"})

      assert :ok = perform_job(SyncScheduler, %{"kind" => "git"})
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id})
      refute_enqueued(worker: JiraSync)

      assert :ok = perform_job(SyncScheduler, %{"kind" => "jira"})
      assert_enqueued(worker: JiraSync)
    end
  end

  describe "JiraSync (Req.Test)" do
    setup do
      prev = Application.get_env(:retrieval_node, :jira_req_options)
      Application.put_env(:retrieval_node, :jira_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.put_env(:retrieval_node, :jira_req_options, prev) end)
      :ok
    end

    test "ingests resolved issues, enqueues ChunkFiles, advances the watermark" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "proj", identifier: "PROJ"})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "PROJ-42",
              "fields" => %{
                "summary" => "A resolved issue",
                "resolutiondate" => "2026-03-01T00:00:00.000+0000"
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      [raw] = Repo.all(PendingChunk)
      assert raw.natural_key == "jira:PROJ-42"
      assert raw.source_type == "jira_project"
      assert raw.raw_content =~ "A resolved issue"
      assert_enqueued(worker: RetrievalNode.Ingest.Workers.ChunkFiles)

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-01T00:00:00.000+0000"
    end

    test "a 429 returns {:snooze, _} instead of failing" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:snooze, 30} = perform_job(JiraSync, %{"source_id" => source.id})
    end

    test "a 429 with a non-integer Retry-After falls back to the default (no crash)" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        # an HTTP-date is RFC-valid but not delta-seconds — must NOT raise
        |> Plug.Conn.put_resp_header("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:snooze, 60} = perform_job(JiraSync, %{"source_id" => source.id})
    end
  end

  describe "DriveSync (Req.Test)" do
    setup do
      prev = Application.get_env(:retrieval_node, :drive_req_options)
      Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.put_env(:retrieval_node, :drive_req_options, prev) end)
      :ok
    end

    test "first run with no cursor seeds the startPageToken and stages nothing" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "seed", identifier: "root"})

      Req.Test.stub(__MODULE__, fn conn ->
        assert String.ends_with?(conn.request_path, "/changes/startPageToken")
        Req.Test.json(conn, %{"startPageToken" => "tok-seed"})
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      assert Repo.all(PendingChunk) == []
      refute_enqueued(worker: ChunkFiles)
      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["start_page_token"] == "tok-seed"
    end

    test "exports a changed Doc, stages it, prunes a removed Doc, advances the cursor" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

      # already seeded from a prior run, so this sync pages real changes
      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      # a pre-existing chunk for the doc that this sync reports as removed
      Repo.insert!(
        Chunk.upsert_changeset(%Chunk{}, %{
          source_id: source.id,
          source_type: :drive_folder,
          chunk_key: "old-key",
          content_hash: "h",
          content: "old",
          context_breadcrumb: "Design Doc",
          metadata: %{"doc_id" => "d2"}
        })
      )

      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/export") do
          Plug.Conn.send_resp(conn, 200, "# Design Doc\n\nbody text")
        else
          Req.Test.json(conn, %{
            "newStartPageToken" => "tok-9",
            "changes" => [
              %{
                "fileId" => "d1",
                "file" => %{
                  "id" => "d1",
                  "name" => "Design Doc",
                  "mimeType" => "application/vnd.google-apps.document"
                }
              },
              %{"fileId" => "d2", "removed" => true}
            ]
          })
        end
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      [raw] = Repo.all(PendingChunk)
      assert raw.natural_key == "drive:d1"
      assert raw.source_type == "drive_folder"
      assert raw.raw_content =~ "Design Doc"
      assert_enqueued(worker: ChunkFiles)

      # removed doc's chunk pruned
      assert Repo.aggregate(Chunk, :count, :id) == 0

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["start_page_token"] == "tok-9"
    end

    test "a failed export does NOT advance the cursor (no permanent skip)" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})
      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/export") do
          Plug.Conn.send_resp(conn, 500, "boom")
        else
          Req.Test.json(conn, %{
            "newStartPageToken" => "tok-next",
            "changes" => [
              %{
                "fileId" => "d1",
                "file" => %{
                  "id" => "d1",
                  "name" => "Doc",
                  "mimeType" => "application/vnd.google-apps.document"
                }
              }
            ]
          })
        end
      end)

      assert {:error, :export_incomplete} = perform_job(DriveSync, %{"source_id" => source.id})

      # cursor left un-advanced (still tok-0, not tok-next) so the next run re-pages
      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["start_page_token"] == "tok-0"
    end

    test "a 429 returns {:snooze, _} and writes nothing" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:snooze, 45} = perform_job(DriveSync, %{"source_id" => source.id})
      assert Repo.all(PendingChunk) == []
      refute_enqueued(worker: ChunkFiles)
    end

    test "a 429 with a missing Retry-After falls back to the default (no crash)" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, "rate limited")
      end)

      assert {:snooze, 60} = perform_job(DriveSync, %{"source_id" => source.id})
    end

    test "a removal claims a tombstone at a higher generation and removes the doc's permanent chunks" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      Repo.insert!(
        Chunk.upsert_changeset(%Chunk{}, %{
          source_id: source.id,
          source_type: :drive_folder,
          chunk_key: "old-key",
          content_hash: "h",
          content: "old",
          context_breadcrumb: "Design Doc",
          metadata: %{"doc_id" => "d1"}
        })
      )

      # Simulate a version already having been claimed for d1 too.
      Repo.insert!(%FileVersion{
        source_id: source.id,
        identity: "d1",
        identity_hash: Ingest.identity_hash("d1"),
        generation: 1
      })

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "newStartPageToken" => "tok-1",
          "changes" => [%{"fileId" => "d1", "removed" => true}]
        })
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      assert Repo.aggregate(Chunk, :count, :id) == 0

      # The file_versions row is NEVER deleted — deletion is a tombstone
      # claim, not a guard-row delete. The claimed generation is strictly
      # greater than the prior one.
      tombstone = Repo.get_by!(FileVersion, source_id: source.id, identity: "d1")
      assert tombstone.generation > 1
    end

    test "THE HOLE: a delayed pre-deletion UpsertChunks job is stale, not a resurrection" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      # v1's raw row is staged and ChunkFiles enqueued, but NOT yet run — an
      # hours-deep backlog stalls it right here.
      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/export") do
          Plug.Conn.send_resp(conn, 200, "# Design Doc\n\nv1 body")
        else
          Req.Test.json(conn, %{
            "newStartPageToken" => "tok-1",
            "changes" => [
              %{
                "fileId" => "d1",
                "file" => %{
                  "id" => "d1",
                  "name" => "Design Doc",
                  "mimeType" => "application/vnd.google-apps.document"
                }
              }
            ]
          })
        end
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      raw1 = Repo.one!(from p in PendingChunk, where: p.status == "raw")

      # The doc is removed and re-synced BEFORE v1's pipeline ever runs.
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "newStartPageToken" => "tok-2",
          "changes" => [%{"fileId" => "d1", "removed" => true}]
        })
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      # The tombstone claim landed for d1, at a generation greater than
      # raw1's id (same pending_chunks id sequence the deletion drew from).
      tombstone = Repo.get_by!(FileVersion, source_id: source.id, identity: "d1")
      assert tombstone.generation > raw1.id

      # v1's stalled pipeline finally runs to completion.
      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw1.id})
      ids = Repo.all(from p in PendingChunk, select: p.id)
      assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
      ids = Repo.all(from p in PendingChunk, where: p.id in ^ids, select: p.id)
      assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})

      # No chunk was resurrected for d1, and staging is fully drained — the
      # stale claim still cleans up its own staging rows.
      assert Repo.aggregate(from(c in Chunk, where: c.source_id == ^source.id), :count, :id) == 0
      assert Repo.aggregate(PendingChunk, :count, :id) == 0

      # The tombstone's generation is untouched by the stale claim.
      assert Repo.get_by!(FileVersion, source_id: source.id, identity: "d1").generation ==
               tombstone.generation
    end

    test "a removal that loses to an already-higher committed generation leaves that version's chunks untouched" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      # Simulate a newer version of "newer-doc" that already committed at a
      # generation higher than anything this deletion's tombstone draw could
      # produce.
      future_generation = Ingest.next_ingest_generation(Repo) + 1_000_000

      Repo.insert!(
        Chunk.upsert_changeset(%Chunk{}, %{
          source_id: source.id,
          source_type: :drive_folder,
          chunk_key: "future-key",
          content_hash: "h",
          content: "future content",
          context_breadcrumb: "Design Doc",
          metadata: %{"doc_id" => "newer-doc"},
          ingest_generation: future_generation
        })
      )

      Repo.insert!(%FileVersion{
        source_id: source.id,
        identity: "newer-doc",
        identity_hash: Ingest.identity_hash("newer-doc"),
        generation: future_generation
      })

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "newStartPageToken" => "tok-1",
          "changes" => [%{"fileId" => "newer-doc", "removed" => true}]
        })
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      # The deletion's claim lost (:stale) — the newer chunk is untouched and
      # the tombstone's generation is unchanged.
      assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "future-key"), :count, :id) ==
               1

      assert Repo.get_by!(FileVersion, source_id: source.id, identity: "newer-doc").generation ==
               future_generation
    end
  end

  describe "worker uniqueness" do
    setup do
      :ok
    end

    test "ChunkFiles dedups a second enqueue for the same pending_chunk_id" do
      assert {:ok, _} = Oban.insert(ChunkFiles.new(%{"pending_chunk_id" => 123}))
      assert {:ok, job} = Oban.insert(ChunkFiles.new(%{"pending_chunk_id" => 123}))
      # the unique constraint collapses the duplicate onto the first job
      assert job.conflict?
      assert Repo.aggregate(Oban.Job, :count, :id) == 1
    end
  end
end
