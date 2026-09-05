defmodule RetrievalNode.Ingest.SourcesTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.{Drive, Jira}

  alias RetrievalNode.Ingest.Workers.{
    DriveSync,
    JiraSync,
    RepoSync,
    SyncScheduler
  }

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

    test "stages a raw row per resolved issue, advances the watermark" do
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
      assert raw.status == "raw"
      assert raw.raw_content =~ "A resolved issue"

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-01T00:00:00.000+0000"
    end

    test "no resolved issues still advances nothing but is not an error" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"issues" => []}) end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})
      assert Repo.all(PendingChunk) == []

      state = Repo.get_by!(SyncState, source_id: source.id)
      # Cursor (watermark) stays untouched, but last_synced_at is set (it was nil
      # on the freshly created state) so operational status doesn't read "never"
      # for a project that syncs successfully with no resolved issues.
      refute Map.has_key?(state.cursor, "resolutiondate_watermark")
      refute is_nil(state.last_synced_at)
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

    test "an issue whose extracted text is binary stages a deletion entry instead of a content row" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "proj", identifier: "PROJ"})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "PROJ-99",
              "fields" => %{
                # a NUL byte is valid UTF-8 but trips Chunking.binary_content?/1 —
                # defensive: Jira's own ADF extraction shouldn't produce this.
                "summary" => "weird\u0000issue",
                "resolutiondate" => "2026-03-01T00:00:00.000+0000"
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      [row] = Repo.all(PendingChunk)
      assert row.natural_key == "jira:PROJ-99"
      assert row.status == "deleted"
      assert row.raw_content == nil

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-01T00:00:00.000+0000"
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
      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["start_page_token"] == "tok-seed"
    end

    test "exports a changed Doc, stages a deletion entry for a removed one, advances the cursor" do
      source =
        Repo.insert!(%Source{source_type: :drive_folder, name: "folder", identifier: "root"})

      # already seeded from a prior run, so this sync pages real changes
      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      # a pre-existing chunk for the doc that this sync reports as removed —
      # DriveSync only stages a deletion entry now; it never touches `chunks`
      # itself (Ingest.SourceOwner does, when it applies the entry).
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

      raw = Repo.one!(from p in PendingChunk, where: p.natural_key == "drive:d1")
      assert raw.source_type == "drive_folder"
      assert raw.status == "raw"
      assert raw.raw_content =~ "Design Doc"

      deletion = Repo.one!(from p in PendingChunk, where: p.natural_key == "drive:d2")
      assert deletion.status == "deleted"
      assert deletion.metadata == %{"doc_id" => "d2"}

      # the old chunk is untouched here — staging a deletion entry isn't
      # applying it
      assert Repo.aggregate(Chunk, :count, :id) == 1

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["start_page_token"] == "tok-9"
    end

    test "an exported Doc whose content is binary stages a deletion entry instead of a content row" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})
      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      # a pre-existing chunk from when this doc was exportable as text
      Repo.insert!(
        Chunk.upsert_changeset(%Chunk{}, %{
          source_id: source.id,
          source_type: :drive_folder,
          chunk_key: "old-key",
          content_hash: "h",
          content: "old",
          context_breadcrumb: "Weird Doc",
          metadata: %{"doc_id" => "d1"}
        })
      )

      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/export") do
          Plug.Conn.send_resp(conn, 200, <<0, 255, 216, 0>>)
        else
          Req.Test.json(conn, %{
            "newStartPageToken" => "tok-9",
            "changes" => [
              %{
                "fileId" => "d1",
                "file" => %{
                  "id" => "d1",
                  "name" => "Weird Doc",
                  "mimeType" => "application/vnd.google-apps.document"
                }
              }
            ]
          })
        end
      end)

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      deletion = Repo.one!(from p in PendingChunk, where: p.natural_key == "drive:d1")
      assert deletion.status == "deleted"
      assert deletion.raw_content == nil

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
      assert Repo.all(PendingChunk) == []
    end

    test "a partial page (one export ok, one fails) stages the success but still leaves the cursor put" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})
      Repo.insert!(%SyncState{source_id: source.id, cursor: %{"start_page_token" => "tok-0"}})

      Req.Test.stub(__MODULE__, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/d1/export") ->
            Plug.Conn.send_resp(conn, 200, "# ok doc")

          String.ends_with?(conn.request_path, "/export") ->
            Plug.Conn.send_resp(conn, 500, "boom")

          true ->
            Req.Test.json(conn, %{
              "newStartPageToken" => "tok-next",
              "changes" => [
                %{
                  "fileId" => "d1",
                  "file" => %{
                    "id" => "d1",
                    "name" => "Ok Doc",
                    "mimeType" => "application/vnd.google-apps.document"
                  }
                },
                %{
                  "fileId" => "d2",
                  "file" => %{
                    "id" => "d2",
                    "name" => "Bad Doc",
                    "mimeType" => "application/vnd.google-apps.document"
                  }
                }
              ]
            })
        end
      end)

      assert {:error, :export_incomplete} = perform_job(DriveSync, %{"source_id" => source.id})

      assert Repo.one!(from p in PendingChunk, where: p.natural_key == "drive:d1")
      refute Repo.get_by(PendingChunk, natural_key: "drive:d2")

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
    end

    test "a 429 with a missing Retry-After falls back to the default (no crash)" do
      source = Repo.insert!(%Source{source_type: :drive_folder, name: "f", identifier: "root"})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, "rate limited")
      end)

      assert {:snooze, 60} = perform_job(DriveSync, %{"source_id" => source.id})
    end
  end
end
