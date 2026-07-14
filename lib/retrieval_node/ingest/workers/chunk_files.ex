defmodule RetrievalNode.Ingest.Workers.ChunkFiles do
  @moduledoc """
  Turns one raw staging row into embeddable chunk rows: **scrub → chunk (with the
  fallback policy) → write chunk rows → enqueue EmbedBatch → reap the raw row**.

  Scrub is an in-process pre-step (fail-closed): a `{:cancel, _}` from the scrubber
  (unredactable secret) discards the file; a scrub `{:error, _}` retries. Chunking
  falls back to the heuristic chunker on a parse timeout/crash (final attempt) or an
  unsupported language, but *skips* (`{:cancel}`) oversized/binary content. The raw
  row (which holds pre-scrub secrets) is deleted once its chunk rows are written, so
  it isn't left lingering. Idempotent: a retry after the raw row is gone is a no-op.
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

  @source_types %{"git" => :git_repo, "jira" => :jira_project, "drive" => :drive_folder}

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
        {:cancel, "scrub refused to index content: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
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

    {:ok, rows} =
      PendingChunks.write_chunks(row, attrs,
        chunk_quality: quality,
        scrub_mode: opts[:scrub_mode],
        secrets_status: opts[:secrets_status]
      )

    {:ok, _job} = Oban.insert(EmbedBatch.new(%{"pending_chunk_ids" => Enum.map(rows, & &1.id)}))
    reap(row)
    :ok
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
