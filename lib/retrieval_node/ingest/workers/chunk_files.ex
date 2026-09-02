defmodule RetrievalNode.Ingest.Workers.ChunkFiles do
  @moduledoc """
  Turns one raw staging row into embeddable chunk rows: **scrub → chunk (with the
  fallback policy) → write chunk rows → enqueue EmbedBatch**. `UpsertChunks` is the
  pipeline's ONE terminal stage — every raw row this worker reads ends up routed
  through it, including the zero-chunk case below, which used to reap and
  reconcile locally and is now just another `UpsertChunks` job with an empty chunk
  id list. See `Ingest.Workers.UpsertChunks`' moduledoc for why one terminal path
  (and the atomic per-file version claim it opens its transaction with) replaced
  the two this pipeline used to have.

  Scrub is an in-process pre-step (fail-closed): a `{:cancel, _}` from the scrubber
  (unredactable secret, too-large, or scanner-unavailable) discards the file — and
  because the raw row still holds the un-redacted secret, we **reap it on the cancel
  path too**, never leaving plaintext in staging. Chunking falls back to the
  heuristic chunker on a parse timeout/crash (final attempt) or an unsupported
  language, but *skips* (`{:cancel}`, after reaping) oversized/binary content.

  Normal (non-empty) path: the raw row is deleted once its chunk rows are written.
  Idempotent: a retry after the raw row is gone is a no-op. `finalize/6` runs
  write-chunks → enqueue EmbedBatch → reap in one transaction, so a crash never
  redoes that work under a fresh id set.

  Zero-chunk (e.g. whitespace-only) path: nothing to embed, so there's no
  EmbedBatch stage to run — but the raw row must still reach `UpsertChunks` (it's
  the only place that reconciles a file's chunk set, and a file that stops
  producing chunks entirely still needs its old chunks reaped). The raw row's
  status flips to `"chunked_empty"` and `UpsertChunks` is enqueued directly with
  `pending_chunk_ids: []` and `raw_pending_chunk_id: row.id` — the raw row is
  *not* reaped here; `UpsertChunks` reaps it once it's done with it (its cleanup
  step deletes both the chunk ids in its args and the raw row id, whichever of the
  two exist), so a crash between these two jobs leaves the raw row for the retry
  to pick back up rather than losing the file's stale-chunk reconciliation.

  Every chunk row this worker writes is stamped with `ingest_generation: row.id` —
  the raw row's own (monotonic) id — cheap provenance that `UpsertChunks` copies
  onto the permanent `Chunk` row. `raw_pending_chunk_id` is also threaded onto the
  NORMAL path's `EmbedBatch` args (which forwards it to `UpsertChunks` in turn) so
  `UpsertChunks` always has the raw row id in hand for the empty-batch case without
  ever needing to infer it.
  """
  use Oban.Worker,
    queue: :chunk,
    max_attempts: 5,
    unique: [
      period: {1, :hour},
      keys: [:pending_chunk_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Chunking
  alias RetrievalNode.Chunking.{Breadcrumb, HeuristicImpl}
  alias RetrievalNode.Ingest.{PendingChunks, Scrubber}
  alias RetrievalNode.Ingest.Workers.{EmbedBatch, UpsertChunks}
  alias RetrievalNode.Repo

  @source_types %{"git" => :git_repo, "jira" => :jira_project, "drive" => :drive_folder}

  # finalize/6 threads an %Ecto.Multi{} (opaque) through Oban.insert/3 to enqueue
  # EmbedBatch inside the write+reap transaction — correct at runtime, but dialyzer
  # sees the opaque Multi crossing into Oban. Silence just that call.
  @dialyzer {:no_opaque, finalize: 6}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(45)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_id" => id}, attempt: attempt, max_attempts: max}) do
    case PendingChunks.get(id) do
      nil -> :ok
      row -> scrub_and_chunk(row, attempt, max)
    end
  end

  defp scrub_and_chunk(row, attempt, max) do
    case Scrubber.scrub(row.raw_content, Map.fetch!(@source_types, row.source)) do
      {:ok, result} ->
        record_audit(row, result.findings)
        # Scrubber returns secrets_status as an atom; the staging column is a string.
        opts = [scrub_mode: result.scrub_mode, secrets_status: to_string(result.secrets_status)]
        chunk_and_enqueue(row, result.redacted_content, opts, attempt, max)

      {:cancel, reason} ->
        # The raw row still holds the un-redacted secret that scrub refused to
        # index — reap it so plaintext never lingers in staging (fail-closed).
        reap(row)
        {:cancel, "scrub refused to index content: #{inspect(reason)}"}
    end
  end

  defp chunk_and_enqueue(row, content, opts, attempt, max) do
    case Chunking.chunk_with_graph(content, row.lang || "") do
      {:ok, %{chunks: chunks, entities: entities, references: references}} ->
        finalize(row, chunks, "ok", opts, entities, references)

      {:error, :unsupported_language} ->
        heuristic_fallback(row, content, "heuristic_fallback", opts)

      {:error, err} when err in [:too_large, :binary_content] ->
        reap(row)
        {:cancel, "content #{err}, skipping"}

      {:error, _err} when attempt >= max ->
        heuristic_fallback(row, content, "crashed_fallback", opts)

      {:error, err} ->
        {:error, err}
    end
  end

  defp heuristic_fallback(row, content, parse_status, opts) do
    {:ok, chunks} = HeuristicImpl.chunk(content, row.lang || "")
    quality_opts = Keyword.put(opts, :chunk_quality, "heuristic_fallback")
    # The heuristic chunker has no AST to walk — no entities/references to attach.
    finalize(row, chunks, parse_status, quality_opts, [], [])
  end

  # No chunks (e.g. a file that changed to whitespace-only) — nothing to embed
  # or claim a version for here. Mark the raw row `chunked_empty` (it still
  # carries this file's identity/generation) and route it through
  # `UpsertChunks` directly, the same terminal stage the normal path reaches
  # via EmbedBatch — that's the only place a version is claimed and a file's
  # chunk set reconciled, so a file that stops producing chunks entirely
  # still gets its stale chunks (from a prior ingest) reaped there, in the
  # same atomic, order-safe way as any other version. `raw_pending_chunk_id`
  # (not `pending_chunk_id` — this staging table also holds already-chunked
  # rows) is how `UpsertChunks` finds this row for an otherwise-empty batch.
  defp finalize(row, [], _parse_status, _opts, _entities, _references) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:mark_empty, fn repo, _ ->
      case repo.update_all(PendingChunks.by_ids([row.id]),
             set: [status: "chunked_empty", updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> {:ok, :marked}
        {0, _} -> {:error, :raw_row_missing}
      end
    end)
    |> Oban.insert(:upsert, fn _changes ->
      UpsertChunks.new(%{"pending_chunk_ids" => [], "raw_pending_chunk_id" => row.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp finalize(row, chunks, parse_status, opts, entities, references) do
    quality = opts[:chunk_quality] || "tree_sitter"
    graphs = attach_graphs(chunks, entities, references)

    attrs =
      [chunks, graphs]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map(fn {{chunk, graph}, index} ->
        chunk_attrs(row, chunk, index, parse_status, graph)
      end)

    # write chunks → enqueue EmbedBatch → reap raw, atomically. A crash in this
    # window rolls all three back, so the retry (raw row still present) redoes the
    # work cleanly rather than orphaning a second chunk-row set under a new id.
    Ecto.Multi.new()
    |> Ecto.Multi.run(:chunks, fn _repo, _ ->
      PendingChunks.write_chunks(row, attrs,
        chunk_quality: quality,
        scrub_mode: opts[:scrub_mode],
        secrets_status: opts[:secrets_status]
      )
    end)
    |> Oban.insert(:embed, fn %{chunks: rows} ->
      EmbedBatch.new(%{
        "pending_chunk_ids" => Enum.map(rows, & &1.id),
        "raw_pending_chunk_id" => row.id
      })
    end)
    |> Ecto.Multi.run(:reap, fn repo, _ ->
      {:ok, repo.delete_all(PendingChunks.by_ids([row.id]))}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp chunk_attrs(row, chunk, index, parse_status, graph) do
    %{
      chunk_index: index,
      chunk_content: chunk.text,
      chunk_key: chunk_key(row, chunk, index),
      context_breadcrumb: Breadcrumb.build(file_prefix(row), chunk.breadcrumb),
      parse_status: parse_status,
      graph: graph,
      # This raw row's own id — see the `chunks.ingest_generation` migration.
      ingest_generation: row.id
    }
  end

  # chunk_key = sha256 over the natural key + chunk ordinal + symbol trail — a
  # stable identity so re-ingesting the same file upserts (not duplicates).
  defp chunk_key(row, chunk, index) do
    :crypto.hash(:sha256, "#{row.natural_key}|#{index}|#{chunk.breadcrumb}")
    |> Base.encode16(case: :lower)
  end

  defp file_prefix(row), do: Map.get(row.metadata || %{}, "path") || row.natural_key

  # Assigns each entity/reference to the chunk whose start_line..end_line contains
  # its line; items matching no chunk (typically a top-level import sitting
  # between two defs) attach to the FIRST chunk of the file rather than being
  # dropped — imports are file-level signal and losing them would gut the
  # imports leg of the graph. Chunks with no graph items get %{} (the staging
  # column default), cheaper than an empty-list map repeated over 380k prose
  # chunks that have no graph data at all.
  defp attach_graphs(chunks, entities, references) do
    entities_by_chunk =
      Enum.group_by(entities, &chunk_index_for(&1.line, chunks), &entity_attrs/1)

    references_by_chunk =
      Enum.group_by(references, &chunk_index_for(&1.line, chunks), &reference_attrs/1)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {_chunk, index} ->
      graph_attrs(Map.get(entities_by_chunk, index, []), Map.get(references_by_chunk, index, []))
    end)
  end

  defp graph_attrs([], []), do: %{}

  defp graph_attrs(entities, references),
    do: %{"entities" => entities, "references" => references}

  defp chunk_index_for(line, chunks) do
    case Enum.find_index(chunks, &(line >= &1.start_line and line <= &1.end_line)) do
      nil -> 0
      index -> index
    end
  end

  defp entity_attrs(entity),
    do: %{"qualified_name" => entity.qualified_name, "kind" => to_string(entity.kind)}

  defp reference_attrs(ref),
    do: %{"name" => ref.name, "kind" => to_string(ref.kind), "from" => ref.from}

  defp record_audit(_row, []), do: :ok

  defp record_audit(row, findings) do
    Scrubber.record_findings(findings, %{
      source_id: row.source_id,
      file_reference: row.natural_key
    })
  end

  defp reap(row), do: PendingChunks.delete_by_ids([row.id])
end
