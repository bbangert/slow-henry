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
  raw row is gone is a no-op. `finalize/4` runs write-chunks → enqueue → reap in one
  transaction, so a crash never redoes that work under a fresh id set.
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
  alias RetrievalNode.Ingest.Workers.EmbedBatch
  alias RetrievalNode.Repo

  @source_types %{"git" => :git_repo, "jira" => :jira_project, "drive" => :drive_folder}

  # finalize/4 threads an %Ecto.Multi{} (opaque) through Oban.insert/3 to enqueue
  # EmbedBatch inside the write+reap transaction — correct at runtime, but dialyzer
  # sees the opaque Multi crossing into Oban. Silence just that call.
  @dialyzer {:no_opaque, finalize: 4}

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
    case Chunking.chunk(content, row.lang || "") do
      {:ok, chunks} ->
        finalize(row, chunks, "ok", opts)

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
    finalize(row, chunks, parse_status, Keyword.put(opts, :chunk_quality, "heuristic_fallback"))
  end

  # No chunks (e.g. whitespace-only file) — nothing to embed; just reap the raw row.
  defp finalize(row, [], _parse_status, _opts) do
    reap(row)
    :ok
  end

  defp finalize(row, chunks, parse_status, opts) do
    quality = opts[:chunk_quality] || "tree_sitter"

    attrs =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} -> chunk_attrs(row, chunk, index, parse_status) end)

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

  defp chunk_attrs(row, chunk, index, parse_status) do
    %{
      chunk_index: index,
      chunk_content: chunk.text,
      chunk_key: chunk_key(row, chunk, index),
      context_breadcrumb: Breadcrumb.build(file_prefix(row), chunk.breadcrumb),
      parse_status: parse_status
    }
  end

  # chunk_key = sha256 over the natural key + chunk ordinal + symbol trail — a
  # stable identity so re-ingesting the same file upserts (not duplicates).
  defp chunk_key(row, chunk, index) do
    :crypto.hash(:sha256, "#{row.natural_key}|#{index}|#{chunk.breadcrumb}")
    |> Base.encode16(case: :lower)
  end

  defp file_prefix(row), do: Map.get(row.metadata || %{}, "path") || row.natural_key

  defp record_audit(_row, []), do: :ok

  defp record_audit(row, findings) do
    Scrubber.record_findings(findings, %{
      source_id: row.source_id,
      file_reference: row.natural_key
    })
  end

  defp reap(row), do: PendingChunks.delete_by_ids([row.id])
end
