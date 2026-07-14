defmodule RetrievalNode.Ingest.SourcesTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.{Drive, Jira}
  alias RetrievalNode.Ingest.Workers.{ChunkFiles, DriveSync, JiraSync, RepoSync, SyncScheduler}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

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
      start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})
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
      start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})
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
  end

  describe "DriveSync (Req.Test)" do
    setup do
      start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})
      prev = Application.get_env(:retrieval_node, :drive_req_options)
      Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.put_env(:retrieval_node, :drive_req_options, prev) end)
      :ok
    end

    test "exports a changed Doc, stages it, prunes a removed Doc, advances the cursor" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

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

      # cursor left un-advanced so the next run re-fetches the same page
      state = Repo.get_by!(SyncState, source_id: source.id)
      refute Map.get(state.cursor || %{}, "start_page_token")
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
  end

  describe "worker uniqueness" do
    setup do
      start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})
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
