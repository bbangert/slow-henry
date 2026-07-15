defmodule RetrievalNode.Ingest.Workers.UpsertChunks do
  @moduledoc """
  Terminal ingest stage: idempotently upsert the embedded staging rows into the
  permanent `Retrieval.Chunk` table, then delete the consumed `pending_chunks`.

  Idempotent via `ON CONFLICT (source_id, chunk_key)` — re-running (a retry, a
  webhook/cron overlap, a re-sync) replaces the row rather than duplicating it.
  The insert + staging cleanup run in one transaction so a crash never leaves the
  chunk written but the staging row lingering (or vice-versa).
  """
  use Oban.Worker,
    queue: :upsert,
    max_attempts: 5,
    unique: [
      period: {30, :minutes},
      keys: [:pending_chunk_ids],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk

  # The staged `embedding` is a %Pgvector{} (opaque) that we pass straight into
  # insert_all — correct at runtime (the vector type's dump is a passthrough), but
  # dialyzer sees an opaque term crossing into Ecto.Multi. Silence just that.
  @dialyzer {:no_opaque, perform: 1}

  @replace_on_conflict [
    :content,
    :content_hash,
    :embedding,
    :context_breadcrumb,
    :metadata,
    :parse_status,
    :secrets_status,
    :updated_at
  ]

  # Same 65,535-bind-parameter ceiling as PendingChunks.insert_raw_all/1 (see its
  # moduledoc). All ids here come from ONE ChunkFiles job's worth of chunks (a
  # single source file), which is normally small — but a pathological file (many
  # tiny blank-line-delimited chunks, see Chunking.HeuristicImpl) can still push a
  # single file's chunk count into the tens of thousands, so batch defensively
  # too. ~12 params/row here as well → 2,000/batch stays well under the limit.
  @insert_batch_size 2_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids}}) do
    entries = ids |> PendingChunks.fetch_many!() |> Enum.map(&to_chunk_entry/1)
    now = DateTime.utc_now()

    Ecto.Multi.new()
    |> Ecto.Multi.run(:chunks, fn repo, _ -> {:ok, insert_batches(repo, entries, now)} end)
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      {:ok, repo.delete_all(PendingChunks.by_ids(ids))}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp insert_batches(repo, entries, now) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.each(fn batch ->
      repo.insert_all(Chunk, batch,
        placeholders: %{now: now},
        on_conflict: {:replace, @replace_on_conflict},
        conflict_target: [:source_id, :chunk_key]
      )
    end)
  end

  defp insert_batch_size,
    do: Application.get_env(:retrieval_node, :upsert_chunks_batch_size, @insert_batch_size)

  defp to_chunk_entry(row) do
    %{
      source_id: row.source_id,
      # staged enums are strings; insert_all's dump wants the atom.
      source_type: to_enum(:source_type, row.source_type),
      repo: row.repo,
      lang: row.lang,
      chunk_key: row.chunk_key,
      # Chunk.content_hash is the hash of the CHUNK (row.content_hash is the raw-file hash).
      content_hash: sha256(row.chunk_content),
      content: row.chunk_content,
      context_breadcrumb: row.context_breadcrumb,
      metadata: row.metadata,
      embedding: row.embedding,
      parse_status: to_enum(:parse_status, row.parse_status),
      secrets_status: to_enum(:secrets_status, row.secrets_status),
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # Resolve staged enum strings against the Chunk schema's own Ecto.Enum
  # mappings rather than String.to_existing_atom/1: the latter depends on some
  # already-loaded module having interned the atom, which is load-order
  # dependent under the BEAM's lazy (interactive-mode) module loading — e.g.
  # :heuristic_fallback only enters the atom table once a module using it is
  # loaded. Mappings are also a strict allowlist: an unknown string raises
  # instead of resolving to an unrelated pre-existing atom.
  defp to_enum(_field, nil), do: nil
  defp to_enum(_field, value) when is_atom(value), do: value

  defp to_enum(field, value) when is_binary(value) do
    Chunk
    |> Ecto.Enum.mappings(field)
    |> Enum.find(fn {_atom, dump} -> dump == value end)
    |> case do
      {atom, _dump} ->
        atom

      nil ->
        raise ArgumentError,
              "#{inspect(value)} is not a valid dump value for Chunk.#{field} " <>
                "(expected one of #{inspect(Ecto.Enum.dump_values(Chunk, field))})"
    end
  end

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
