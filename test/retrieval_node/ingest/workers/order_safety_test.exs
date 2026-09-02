defmodule RetrievalNode.Ingest.Workers.OrderSafetyTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # that the application tree starts (same reason as UpsertChunksTest).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import ExUnit.CaptureLog

  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Ingest.Workers.{ChunkFiles, EmbedBatch, UpsertChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  # Test env sets Logger level: :warning, which drops the :info "skipping
  # stale..."/"reconciled..." log lines before capture_log ever sees them —
  # bump it for this whole module (same pattern as UpsertChunksTest's
  # whitespace-only describe block). Already async: false.
  setup do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    prev_impl = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev_impl)
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

  defp force_chunk_with_graph(result),
    do: Application.put_env(:retrieval_node, :fake_chunk_with_graph_result, result)

  defp chunk_result(specs) do
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

    {:ok, %{chunks: chunks, entities: [], references: []}}
  end

  # Runs ChunkFiles for `raw` only (does not touch any other staged rows —
  # the out-of-order tests deliberately stage a second raw row first).
  defp run_chunk_files(raw), do: perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

  # Runs EmbedBatch -> UpsertChunks for exactly the chunk rows `raw` produced
  # (scoped by content_hash, since more than one raw row's chunks can be
  # staged at once in the out-of-order tests below).
  defp run_rest_of_pipeline(raw) do
    ids =
      Repo.all(from p in PendingChunk, where: p.content_hash == ^raw.content_hash, select: p.id)

    assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
    ids = Repo.all(from p in PendingChunk, where: p.id in ^ids, select: p.id)
    perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})
  end

  defp run_pipeline(raw) do
    assert :ok = run_chunk_files(raw)
    run_rest_of_pipeline(raw)
  end

  defp persisted_chunks(source, path) do
    Chunk
    |> where([c], c.source_id == ^source.id)
    |> where([c], fragment("?->>'path'", c.metadata) == ^path)
    |> Repo.all()
  end

  test "in-order: v1 then v2 lands v2's content with generation = v2's raw id", %{
    source: source
  } do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(chunk_result([{"v1 content", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "app.py")
    assert :ok = run_pipeline(raw1)

    force_chunk_with_graph(chunk_result([{"v2 content", "a", 1, 1}]))
    raw2 = seed_raw(source, "v2", natural_key, "app.py")
    assert :ok = run_pipeline(raw2)

    assert [chunk] = persisted_chunks(source, "app.py")
    assert chunk.content == "v2 content"
    assert chunk.ingest_generation == raw2.id
  end

  test "out-of-order: v2 processed first, then v1's terminal job is skipped and v2 is untouched",
       %{source: source} do
    natural_key = "repo:acme/app:app.py"

    # Stage BOTH raw rows up front — raw1 (older, lower id) and raw2 (newer,
    # higher id) — before either is processed, simulating a v1 job stuck
    # behind an hours-deep :embed backlog while v2 (a later edit) races
    # ahead of it.
    force_chunk_with_graph(chunk_result([{"v1 content", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "app.py")

    force_chunk_with_graph(chunk_result([{"v2 content", "a", 1, 1}]))
    raw2 = seed_raw(source, "v2", natural_key, "app.py")

    assert raw2.id > raw1.id

    # v2's full pipeline runs to completion first.
    assert :ok = run_pipeline(raw2)
    assert [v2_chunk] = persisted_chunks(source, "app.py")
    assert v2_chunk.content == "v2 content"
    assert v2_chunk.ingest_generation == raw2.id

    # v1's job finally runs (ChunkFiles, then EmbedBatch, then the terminal
    # UpsertChunks that must recognize it's stale and skip).
    assert :ok = run_chunk_files(raw1)

    log =
      capture_log(fn ->
        assert :ok = run_rest_of_pipeline(raw1)
      end)

    assert log =~ "skipping stale ingest generation #{raw1.id} < #{raw2.id} for path=app.py"

    # v2's chunk is untouched — same row, same content, same generation.
    assert [chunk_after] = persisted_chunks(source, "app.py")
    assert chunk_after.id == v2_chunk.id
    assert chunk_after.content == "v2 content"
    assert chunk_after.ingest_generation == raw2.id

    # v1's staging rows (raw + chunked) were still cleaned up.
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "zero-chunk out-of-order: a delayed whitespace-only v1 job does not delete v2's chunks",
       %{source: source} do
    natural_key = "repo:acme/app:app.py"

    # v1 (older) is staged whitespace-only content but NOT processed yet.
    force_chunk_with_graph(chunk_result([]))
    raw1 = seed_raw(source, "   \n\t\n  ", natural_key, "app.py")

    # v2 (newer) has real content and runs to completion.
    force_chunk_with_graph(chunk_result([{"v2 content", "a", 1, 1}]))
    raw2 = seed_raw(source, "v2", natural_key, "app.py")
    assert :ok = run_pipeline(raw2)
    assert [v2_chunk] = persisted_chunks(source, "app.py")

    # The delayed v1 whitespace-only ChunkFiles job finally runs.
    force_chunk_with_graph(chunk_result([]))

    log =
      capture_log(fn ->
        assert :ok = run_chunk_files(raw1)
      end)

    assert log =~ "skipping stale ingest generation #{raw1.id} < #{raw2.id} for path=app.py"
    refute log =~ "chunk_files reconciled"

    # v2's chunk survives untouched; v1's raw row is still reaped.
    assert [chunk_after] = persisted_chunks(source, "app.py")
    assert chunk_after.id == v2_chunk.id
    refute Repo.get(PendingChunk, raw1.id)
  end

  test "zero-chunk forward-order: a newer whitespace-only version still deletes the older chunks",
       %{source: source} do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(chunk_result([{"v1 content", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "app.py")
    assert :ok = run_pipeline(raw1)
    assert [_v1_chunk] = persisted_chunks(source, "app.py")

    force_chunk_with_graph(chunk_result([]))
    raw2 = seed_raw(source, "   \n  ", natural_key, "app.py")
    assert raw2.id > raw1.id

    log =
      capture_log(fn ->
        assert :ok = run_chunk_files(raw2)
      end)

    refute log =~ "skipping stale"
    assert log =~ "chunk_files reconciled 1 stale chunk row(s)"

    assert persisted_chunks(source, "app.py") == []
    refute Repo.get(PendingChunk, raw2.id)
  end

  test "same-generation retry proceeds normally (idempotent), not treated as stale", %{
    source: source
  } do
    natural_key = "repo:acme/app:app.py"

    force_chunk_with_graph(chunk_result([{"v1 content", "a", 1, 1}]))
    raw = seed_raw(source, "v1", natural_key, "app.py")
    assert :ok = run_pipeline(raw)

    assert [original] = persisted_chunks(source, "app.py")
    assert original.ingest_generation == raw.id

    # Simulate a retried delivery of the SAME file version (e.g. EmbedBatch
    # retried and re-enqueued UpsertChunks for the same generation) by
    # re-staging a chunk row carrying the identical chunk_key and the
    # identical `ingest_generation` — the raw row itself is long gone
    # (reaped after the first run), but its provenance only needs to match
    # for `write_chunks/3`, which never re-reads the DB row.
    fake_raw = %PendingChunk{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: "acme/app",
      lang: "python",
      natural_key: natural_key,
      content_hash: "rawhash-retry",
      metadata: %{"path" => "app.py"}
    }

    {:ok, [retry_row]} =
      PendingChunks.write_chunks(fake_raw, [
        %{
          chunk_index: 0,
          chunk_content: "v1 content",
          chunk_key: original.chunk_key,
          context_breadcrumb: "a",
          parse_status: "ok",
          graph: %{},
          ingest_generation: raw.id
        }
      ])

    log =
      capture_log(fn ->
        assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => [retry_row.id]})
        ids = Repo.all(from p in PendingChunk, where: p.id == ^retry_row.id, select: p.id)
        assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})
      end)

    refute log =~ "skipping stale"

    assert [after_retry] = persisted_chunks(source, "app.py")
    assert after_retry.chunk_key == original.chunk_key
    assert after_retry.content == "v1 content"
    assert after_retry.ingest_generation == raw.id
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end
end
