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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids}}) do
    entries = ids |> PendingChunks.fetch_many!() |> Enum.map(&to_chunk_entry/1)

    Ecto.Multi.new()
    |> Ecto.Multi.insert_all(:chunks, Chunk, entries,
      placeholders: %{now: DateTime.utc_now()},
      on_conflict: {:replace, @replace_on_conflict},
      conflict_target: [:source_id, :chunk_key]
    )
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      {:ok, repo.delete_all(PendingChunks.by_ids(ids))}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp to_chunk_entry(row) do
    %{
      source_id: row.source_id,
      # staged enums are strings; insert_all's dump wants the atom.
      source_type: to_enum(row.source_type),
      repo: row.repo,
      lang: row.lang,
      chunk_key: row.chunk_key,
      # Chunk.content_hash is the hash of the CHUNK (row.content_hash is the raw-file hash).
      content_hash: sha256(row.chunk_content),
      content: row.chunk_content,
      context_breadcrumb: row.context_breadcrumb,
      metadata: row.metadata,
      embedding: row.embedding,
      parse_status: to_enum(row.parse_status),
      secrets_status: to_enum(row.secrets_status),
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  defp to_enum(nil), do: nil
  defp to_enum(value) when is_atom(value), do: value
  defp to_enum(value) when is_binary(value), do: String.to_existing_atom(value)

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
