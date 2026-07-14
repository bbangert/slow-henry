defmodule RetrievalNode.Ingest.PendingChunks do
  @moduledoc """
  Data access for the `pending_chunks` staging table — the ingest pipeline's
  scratch space between Oban stages. One of the `Ingest`-context modules allowed
  to touch `Repo`.

  Flow: `*Sync` inserts `raw` rows → `ChunkFiles` reads a raw row and
  `write_chunks/3`s the split chunk rows → `EmbedBatch` `set_embeddings/1` →
  `UpsertChunks` reads them and `delete_by_ids/1`s the consumed rows.
  """

  import Ecto.Query

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.PendingChunk

  @doc """
  Bulk-insert freshly-discovered raw rows in a single `insert_all` (one round-trip,
  atomic). Rows come from the internal `*Sync` clients; NOT NULL constraints at the
  DB enforce required fields (a malformed row raises → the Oban job retries).
  Returns `{:ok, ids}` (the inserted ids, so callers can enqueue a `ChunkFiles`
  job per row).
  """
  @spec insert_raw_all([map()]) :: {:ok, [integer()]}
  def insert_raw_all(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn attrs ->
        # Map.get (not dot access) so a missing key becomes nil → a consistent DB
        # NOT NULL failure, rather than a KeyError before we ever reach the DB.
        %{
          source: Map.get(attrs, :source),
          source_id: Map.get(attrs, :source_id),
          source_type: Map.get(attrs, :source_type),
          repo: Map.get(attrs, :repo),
          lang: Map.get(attrs, :lang),
          natural_key: Map.get(attrs, :natural_key),
          content_hash: Map.get(attrs, :content_hash),
          raw_content: Map.get(attrs, :raw_content),
          metadata: Map.get(attrs, :metadata, %{}),
          status: "raw",
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, rows} = Repo.insert_all(PendingChunk, entries, returning: [:id])
    {:ok, Enum.map(rows, & &1.id)}
  end

  @doc "Insert a single raw row, returning the persisted record."
  @spec insert_raw(map()) :: {:ok, PendingChunk.t()} | {:error, Ecto.Changeset.t()}
  def insert_raw(attrs) do
    %PendingChunk{} |> PendingChunk.raw_changeset(attrs) |> Repo.insert()
  end

  @doc "Fetch one staging row by id (raises if missing)."
  @spec fetch!(integer()) :: PendingChunk.t()
  def fetch!(id), do: Repo.get!(PendingChunk, id)

  @doc "Fetch one staging row by id, or nil if already consumed (idempotent retries)."
  @spec get(integer()) :: PendingChunk.t() | nil
  def get(id), do: Repo.get(PendingChunk, id)

  @doc "Fetch many staging rows by id (order not guaranteed)."
  @spec fetch_many!([integer()]) :: [PendingChunk.t()]
  def fetch_many!(ids), do: Repo.all(by_ids(ids))

  @doc """
  Split a `raw` row into N chunk rows sharing its `natural_key`/`content_hash`.
  Each `chunk` is `%{chunk_index:, chunk_content:}` (+ optional `:embedding`).
  `opts` may carry `:chunk_quality` and `:scrub_mode`. Returns the inserted rows.
  """
  @spec write_chunks(PendingChunk.t(), [map()], keyword()) ::
          {:ok, [PendingChunk.t()]} | {:error, Ecto.Changeset.t()}
  def write_chunks(%PendingChunk{} = raw, chunks, opts \\ []) do
    base = %{
      # provenance copied from the raw row
      source: raw.source,
      source_id: raw.source_id,
      source_type: raw.source_type,
      repo: raw.repo,
      lang: raw.lang,
      natural_key: raw.natural_key,
      content_hash: raw.content_hash,
      metadata: raw.metadata,
      # staging bookkeeping
      status: "chunked",
      chunk_quality: opts[:chunk_quality],
      scrub_mode: opts[:scrub_mode],
      secrets_status: opts[:secrets_status] || "clean"
    }

    Repo.transaction(fn -> Enum.map(chunks, &insert_chunk_row(base, &1)) end)
  end

  defp insert_chunk_row(base, chunk) do
    case Repo.insert(PendingChunk.chunk_changeset(%PendingChunk{}, Map.merge(base, chunk))) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Write embeddings back onto chunk rows. `pairs` is `[%{id:, embedding:}]`.
  Each update must affect exactly one row — a missing id would otherwise silently
  drop the embedding and leave the row `chunked`, so it rolls the batch back
  (`{:error, {:no_such_pending_chunk, id}}`). Sets `updated_at` (update_all bypasses
  Ecto's automatic timestamps).
  """
  @spec set_embeddings([%{id: integer(), embedding: [float()]}]) ::
          {:ok, :ok} | {:error, {:no_such_pending_chunk, integer()}}
  def set_embeddings(pairs) do
    now = DateTime.utc_now()

    Repo.transaction(fn -> Enum.each(pairs, &update_embedding(&1, now)) end)
  end

  defp update_embedding(%{id: id, embedding: embedding}, now) do
    set = [embedding: Pgvector.new(embedding), status: "embedded", updated_at: now]

    case Repo.update_all(by_ids([id]), set: set) do
      {1, _} -> :ok
      {_other, _} -> Repo.rollback({:no_such_pending_chunk, id})
    end
  end

  @doc "Query for the given ids (composable / used for delete)."
  @spec by_ids([integer()]) :: Ecto.Query.t()
  def by_ids(ids), do: from(p in PendingChunk, where: p.id in ^ids)

  @doc "Delete consumed staging rows by id. Returns the count deleted."
  @spec delete_by_ids([integer()]) :: {non_neg_integer(), nil}
  def delete_by_ids(ids), do: Repo.delete_all(by_ids(ids))
end
