defmodule RetrievalNode.Ingest.Workers.UpsertChunksTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # that the application tree starts (same reason as Graph/RepoSync tests).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import ExUnit.CaptureLog

  alias RetrievalNode.Graph.EntityMention
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Ingest.Workers.{ChunkFiles, EmbedBatch, UpsertChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev)
      Application.delete_env(:retrieval_node, :fake_chunk_with_graph_result)
    end)

    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    %{source: source}
  end

  defp seed_raw(source, content, natural_key, path) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: natural_key,
          content_hash: "rawhash-#{System.unique_integer([:positive])}",
          raw_content: content,
          metadata: %{"path" => path}
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  # Runs ChunkFiles -> EmbedBatch -> UpsertChunks for one raw row, in
  # isolation (the pending_chunks table is expected to hold only this row's
  # descendants when it's called).
  defp run_pipeline(raw) do
    assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})
    ids = Repo.all(from p in PendingChunk, select: p.id)
    assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
    assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})
    ids
  end

  defp force_chunk_with_graph(result),
    do: Application.put_env(:retrieval_node, :fake_chunk_with_graph_result, result)

  defp chunk_result(specs, entities \\ [], references \\ []) do
    chunks =
      Enum.map(specs, fn {text, breadcrumb, start_line, end_line} ->
        %{
          text: text,
          breadcrumb: breadcrumb,
          start_line: start_line,
          end_line: end_line,
          kind: "function_definition",
          parse_status: :ok
        }
      end)

    {:ok, %{chunks: chunks, entities: entities, references: references}}
  end

  defp chunk_keys(source, path) do
    Chunk
    |> where([c], c.source_id == ^source.id)
    |> where([c], fragment("?->>'path'", c.metadata) == ^path)
    |> select([c], c.chunk_key)
    |> Repo.all()
    |> Enum.sort()
  end

  defp embed_batch_jobs,
    do: from(j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(EmbedBatch))

  test "reconciles a file's chunk set: fewer/shifted chunks on re-ingest leaves only the new key set for that path",
       %{source: source} do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(
      chunk_result([
        {"chunk a", "a", 1, 1},
        {"chunk b", "b", 2, 2},
        {"chunk c", "c", 3, 3}
      ])
    )

    run_pipeline(seed_raw(source, "v1", natural_key, "app.py"))
    original_keys = chunk_keys(source, "app.py")
    assert length(original_keys) == 3

    # A def removed earlier in the file shifts everything after it — the new
    # chunk set shares no keys with the old one.
    force_chunk_with_graph(
      chunk_result([
        {"chunk a2", "a2", 1, 1},
        {"chunk b2", "b2", 2, 2}
      ])
    )

    run_pipeline(seed_raw(source, "v2", natural_key, "app.py"))
    new_keys = chunk_keys(source, "app.py")

    assert length(new_keys) == 2
    assert Enum.all?(new_keys, &(&1 not in original_keys))
  end

  test "the orphaned chunk's entity_mentions are removed via FK cascade, not just the graph's own stale-mention cleanup",
       %{source: source} do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(
      chunk_result(
        [
          {"def a():\n    return 1\n", "a", 1, 2},
          {"def gone():\n    return 1\n", "gone", 4, 5}
        ],
        [
          %{qualified_name: "a", kind: :function, line: 1},
          %{qualified_name: "gone", kind: :function, line: 4}
        ]
      )
    )

    run_pipeline(seed_raw(source, "v1", natural_key, "app.py"))
    assert Repo.aggregate(EntityMention, :count, :id) == 2

    # New version drops the "gone" chunk entirely (its breadcrumb changes too,
    # simulating a real boundary shift), so its old row — and definition
    # mention — has no successor in this batch.
    force_chunk_with_graph(
      chunk_result(
        [{"def a2():\n    return 1\n", "a2", 1, 2}],
        [%{qualified_name: "a2", kind: :function, line: 1}]
      )
    )

    run_pipeline(seed_raw(source, "v2", natural_key, "app.py"))

    # Both old chunks (a and gone) are orphaned by the boundary shift — their
    # mentions cascade away with the deleted chunk rows, leaving only the
    # fresh mention for "a2".
    assert Repo.aggregate(EntityMention, :count, :id) == 1
    assert [%{}] = Repo.all(EntityMention)
  end

  test "chunks of a different path in the same source are untouched", %{source: source} do
    other_natural_key = "repo:acme/app:other.py"
    app_natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(chunk_result([{"other chunk", "other", 1, 1}]))
    run_pipeline(seed_raw(source, "other v1", other_natural_key, "other.py"))
    other_keys_before = chunk_keys(source, "other.py")
    assert length(other_keys_before) == 1

    force_chunk_with_graph(
      chunk_result([
        {"chunk a", "a", 1, 1},
        {"chunk b", "b", 2, 2},
        {"chunk c", "c", 3, 3}
      ])
    )

    run_pipeline(seed_raw(source, "app v1", app_natural_key, "app.py"))

    force_chunk_with_graph(chunk_result([{"chunk a2", "a2", 1, 1}]))
    run_pipeline(seed_raw(source, "app v2", app_natural_key, "app.py"))

    assert chunk_keys(source, "app.py") |> length() == 1
    assert chunk_keys(source, "other.py") == other_keys_before
  end

  test "a batch spanning two file identities raises ArgumentError — one ChunkFiles job's chunks always belong to one file, so this is a bug, not something to partition around",
       %{source: source} do
    nk1 = "repo:acme/app:f1.py"
    nk2 = "repo:acme/app:f2.py"

    force_chunk_with_graph(chunk_result([{"f1 chunk a", "a", 1, 1}]))
    raw1 = seed_raw(source, "f1 v1", nk1, "f1.py")
    assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw1.id})

    force_chunk_with_graph(chunk_result([{"f2 chunk a", "a", 1, 1}]))
    raw2 = seed_raw(source, "f2 v1", nk2, "f2.py")
    assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw2.id})

    # A batch spanning two files never happens in production (one ChunkFiles
    # job's chunks always go through one EmbedBatch/UpsertChunks pair, see
    # the moduledoc) — simulate it defensively by merging both files' staged
    # ids into one UpsertChunks call.
    combined_ids = Repo.all(from p in PendingChunk, select: p.id)
    assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => combined_ids})

    assert_raise ArgumentError, ~r/one file identity/, fn ->
      perform_job(UpsertChunks, %{"pending_chunk_ids" => combined_ids})
    end
  end

  test "re-running the same content is idempotent — no rows are deleted, nothing is logged", %{
    source: source
  } do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(
      chunk_result([
        {"chunk a", "a", 1, 1},
        {"chunk b", "b", 2, 2},
        {"chunk c", "c", 3, 3}
      ])
    )

    run_pipeline(seed_raw(source, "v1", natural_key, "app.py"))
    keys_before = chunk_keys(source, "app.py")

    ids_before =
      Chunk
      |> where([c], c.source_id == ^source.id)
      |> select([c], c.id)
      |> Repo.all()
      |> Enum.sort()

    log =
      capture_log(fn ->
        run_pipeline(seed_raw(source, "v1-again", natural_key, "app.py"))
      end)

    refute log =~ "reconciled"

    keys_after = chunk_keys(source, "app.py")

    ids_after =
      Chunk
      |> where([c], c.source_id == ^source.id)
      |> select([c], c.id)
      |> Repo.all()
      |> Enum.sort()

    assert keys_after == keys_before
    assert ids_after == ids_before
  end

  describe "whitespace-only re-ingest (zero chunks) reconciliation" do
    # Test env sets Logger level: :warning, which drops :info messages before
    # capture_log ever sees them — capture_log's own :level option only
    # narrows, never widens, the global level. Bump it for ChunkFiles' :info
    # reconciliation log (same reason/pattern as GraphGcTest); this module is
    # already async: false so the mutation can't bleed into concurrent tests.
    setup do
      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)
      :ok
    end

    test "a file that changes to whitespace-only sheds its previously persisted chunks and their cascaded entity_mentions",
         %{source: source} do
      natural_key = "repo:acme/app:app.py"

      force_chunk_with_graph(
        chunk_result(
          [
            {"def a():\n    return 1\n", "a", 1, 2},
            {"def b():\n    return 1\n", "b", 4, 5}
          ],
          [
            %{qualified_name: "a", kind: :function, line: 1},
            %{qualified_name: "b", kind: :function, line: 4}
          ]
        )
      )

      run_pipeline(seed_raw(source, "v1", natural_key, "app.py"))
      assert length(chunk_keys(source, "app.py")) == 2
      assert Repo.aggregate(EntityMention, :count, :id) == 2

      embed_jobs_before = Repo.aggregate(embed_batch_jobs(), :count, :id)

      # The file is now whitespace-only — zero chunks. ChunkFiles alone (no
      # EmbedBatch stage, there's nothing to embed) only marks the raw row
      # `chunked_empty` and routes it straight to UpsertChunks — the
      # pipeline's one terminal stage, and the only place that reconciles a
      # file's now-stale chunk rows away.
      force_chunk_with_graph(chunk_result([]))
      raw2 = seed_raw(source, "   \n\t\n  ", natural_key, "app.py")

      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw2.id})
      assert Repo.get(PendingChunk, raw2.id).status == "chunked_empty"
      # no NEW EmbedBatch job — the run_pipeline call above already left one
      # (from its own, unrelated ChunkFiles step) in the jobs table, so a bare
      # refute_enqueued would false-positive on that leftover.
      assert Repo.aggregate(embed_batch_jobs(), :count, :id) == embed_jobs_before

      log =
        capture_log(fn ->
          assert :ok =
                   perform_job(UpsertChunks, %{
                     "pending_chunk_ids" => [],
                     "raw_pending_chunk_id" => raw2.id
                   })
        end)

      assert log =~ "upsert_chunks reconciled 2 stale chunk row(s)"

      # raw row reaped by UpsertChunks' own cleanup step
      refute Repo.get(PendingChunk, raw2.id)

      # old chunks (and their cascaded mentions) are gone
      assert chunk_keys(source, "app.py") == []
      assert Repo.aggregate(EntityMention, :count, :id) == 0
    end

    test "a whitespace-only FIRST ingest (no prior chunks) is a harmless no-op", %{
      source: source
    } do
      natural_key = "repo:acme/app:empty.py"

      force_chunk_with_graph(chunk_result([]))
      raw = seed_raw(source, "   \n  ", natural_key, "empty.py")

      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})
      assert Repo.get(PendingChunk, raw.id).status == "chunked_empty"
      refute_enqueued(worker: EmbedBatch)

      log =
        capture_log(fn ->
          assert :ok =
                   perform_job(UpsertChunks, %{
                     "pending_chunk_ids" => [],
                     "raw_pending_chunk_id" => raw.id
                   })
        end)

      refute log =~ "reconciled"
      refute Repo.get(PendingChunk, raw.id)
      assert chunk_keys(source, "empty.py") == []
    end
  end
end
