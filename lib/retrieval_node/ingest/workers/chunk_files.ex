defmodule RetrievalNode.Ingest.Workers.ChunkFiles do
  @moduledoc """
  Turns one raw staging row into embeddable chunk rows: **scrub → chunk (with the
  fallback policy) → write chunk rows → enqueue EmbedBatch → reap the raw row**.

  Scrub is an in-process pre-step (fail-closed): a `{:cancel, _}` from the scrubber
  (unredactable secret, too-large, or scanner-unavailable) discards the file — and
  because the raw row still holds the un-redacted secret, we **reap it on the cancel
  path too**, never leaving plaintext in staging. Chunking falls back to the
  heuristic chunker on a parse timeout/crash (final attempt) or an unsupported
  language, but *skips* (`{:cancel}`, after reaping) oversized/binary content. The
  raw row is deleted once its chunk rows are written. Idempotent: a retry after the
  raw row is gone is a no-op. `finalize/6` runs write-chunks → enqueue → reap in one
  transaction, so a crash never redoes that work under a fresh id set.

  Every chunk row this worker writes is stamped with `ingest_generation: row.id` —
  the raw row's own (monotonic) id. The zero-chunk (whitespace-only) reconciliation
  path below reads that same id back as ITS generation and skips deleting a file's
  persisted chunks when a newer version's generation already beat it there — see
  `Ingest.max_ingest_generation/4` and `Ingest.Workers.UpsertChunks`' moduledoc for
  why (two versions of one file can be in flight; this worker is unique only by
  `pending_chunk_id`, not by file, so the older version's job can run last).
  """
  use Oban.Worker,
    queue: :chunk,
    max_attempts: 5,
    unique: [
      period: {1, :hour},
      keys: [:pending_chunk_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Chunking.{Breadcrumb, HeuristicImpl}
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.{PendingChunks, Scrubber}
  alias RetrievalNode.Ingest.Workers.EmbedBatch
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

  # No chunks (e.g. a file that changed to whitespace-only) — nothing to embed,
  # but this file may have had chunks from a PRIOR ingest (and their cascaded
  # entity_mentions/entity_edges) that are now orphaned: nothing else in the
  # pipeline ever revisits a file that stops producing chunks entirely (see
  # UpsertChunks' moduledoc — its own reconciliation only runs when a batch of
  # NEW chunks arrives). Reconcile this file's identity against an empty
  # keep-set (deletes every existing chunk row for it) and reap the raw row
  # atomically, via the same `Ingest.reconcile_file_chunks/5` UpsertChunks
  # uses — so "delete old chunks" and "reap raw" either both happen or
  # neither does. A harmless no-op when the file has no prior chunks (first
  # ingest) or no resolvable identity (see `Ingest.file_identity/2`).
  defp finalize(row, [], _parse_status, _opts, _entities, _references) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:reconcile, fn repo, _ -> {:ok, reconcile_or_skip_stale(repo, row)} end)
    |> Ecto.Multi.run(:reap, fn repo, _ ->
      {:ok, repo.delete_all(PendingChunks.by_ids([row.id]))}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{reconcile: reconciled}} ->
        if reconciled > 0 do
          Logger.info(
            "chunk_files reconciled #{reconciled} stale chunk row(s) for a whitespace-only file"
          )
        end

        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
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
      EmbedBatch.new(%{"pending_chunk_ids" => Enum.map(rows, & &1.id)})
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

  # Generation guard for the zero-chunk (whitespace-only) reconciliation path:
  # this raw row's generation is its own `id` (bigserial ⇒ monotonic — see the
  # `chunks.ingest_generation` migration). If a NEWER version of this file
  # already has chunks persisted, this (older, delayed) whitespace-only run
  # must NOT delete them — a stale ChunkFiles retry/backlog job racing behind
  # the newer version's UpsertChunks would otherwise wipe out real content.
  # Skip the delete but still let the raw row get reaped (the `:reap` step
  # runs regardless).
  defp reconcile_or_skip_stale(repo, row) do
    persisted = Ingest.max_ingest_generation(repo, row.source_id, row.source_type, row.metadata)

    if persisted > row.id do
      Logger.info(
        "skipping stale ingest generation #{row.id} < #{persisted} for #{identity_label(row)}"
      )

      0
    else
      Ingest.reconcile_file_chunks(repo, row.source_id, row.source_type, row.metadata, [])
    end
  end

  defp identity_label(row) do
    case Ingest.file_identity(row.source_type, row.metadata) do
      {field, value} -> "#{field}=#{value}"
      nil -> "unknown"
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
