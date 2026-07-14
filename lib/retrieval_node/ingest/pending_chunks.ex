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
  Returns `{:ok, count}`.
  """
  @spec insert_raw_all([map()]) :: {:ok, non_neg_integer()}
  def insert_raw_all(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn attrs ->
        %{
          source: attrs.source,
          natural_key: attrs.natural_key,
          content_hash: attrs.content_hash,
          raw_content: attrs.raw_content,
          status: "raw",
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(PendingChunk, entries)
    {:ok, count}
  end

  @doc "Insert a single raw row, returning the persisted record."
  @spec insert_raw(map()) :: {:ok, PendingChunk.t()} | {:error, Ecto.Changeset.t()}
  def insert_raw(attrs) do
    %PendingChunk{} |> PendingChunk.raw_changeset(attrs) |> Repo.insert()
  end

  @doc "Fetch one staging row by id (raises if missing)."
  @spec fetch!(integer()) :: PendingChunk.t()
  def fetch!(id), do: Repo.get!(PendingChunk, id)

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
      source: raw.source,
      natural_key: raw.natural_key,
      content_hash: raw.content_hash,
      status: "chunked",
      chunk_quality: opts[:chunk_quality],
      scrub_mode: opts[:scrub_mode]
    }

    Repo.transaction(fn -> Enum.map(chunks, &insert_chunk_row(base, &1)) end)
  end

  defp insert_chunk_row(base, chunk) do
    case Repo.insert(PendingChunk.chunk_changeset(%PendingChunk{}, Map.merge(base, chunk))) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Write embeddings back onto chunk rows. `pairs` is `[%{id:, embedding:}]`."
  @spec set_embeddings([%{id: integer(), embedding: [float()]}]) :: :ok
  def set_embeddings(pairs) do
    Repo.transaction(fn ->
      Enum.each(pairs, fn %{id: id, embedding: embedding} ->
        by_ids([id])
        |> Repo.update_all(set: [embedding: Pgvector.new(embedding), status: "embedded"])
      end)
    end)

    :ok
  end

  @doc "Query for the given ids (composable / used for delete)."
  @spec by_ids([integer()]) :: Ecto.Query.t()
  def by_ids(ids), do: from(p in PendingChunk, where: p.id in ^ids)

  @doc "Delete consumed staging rows by id. Returns the count deleted."
  @spec delete_by_ids([integer()]) :: {non_neg_integer(), nil}
  def delete_by_ids(ids), do: Repo.delete_all(by_ids(ids))
end
