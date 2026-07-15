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
  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.PendingChunk

  # A single `insert_all` is capped by Postgres's 65,535-bind-parameter wire
  # protocol limit; each row here binds ~12 params, so one statement tops out
  # around ~5,400 rows. 2,000 rows/batch (~24k params) stays comfortably under
  # that ceiling with room to spare for future columns. Config-overridable (like
  # GitMirror's timeout knobs) purely so tests can exercise the multi-batch path
  # without actually constructing 2,000+ rows.
  @insert_batch_size 2_000

  @doc """
  Bulk-insert freshly-discovered raw rows, batched under Postgres's 65,535-bind-
  parameter limit (one `insert_all` per `#{@insert_batch_size}`-row batch), all
  inside one transaction so the whole set stays atomic — a failure in any batch
  rolls back everything already inserted this call. Rows come from the internal
  `*Sync` clients; NOT NULL constraints at the DB enforce required fields (a
  malformed row raises → the transaction rolls back → the Oban job retries).

  A row whose `raw_content` is binary (`Chunking.binary_content?/1`) is dropped
  here, before it ever reaches the `text` column — Postgres rejects invalid UTF-8
  outright (error 22021), which would otherwise crash the whole insert (and the
  calling `*Sync` job) over a single bad file. This is the single choke point all
  `*Sync` workers insert through, so the guard applies uniformly without each
  worker re-implementing it, and runs against the FULL row set before batching (a
  batch boundary never splits a file away from its own guard check). Returns
  `{:ok, ids}` for the rows actually inserted, in the same order as `rows` (minus
  skips) — callers enqueue `ChunkFiles` per returned id, so a skipped row
  correctly gets no chunking job, and callers that zip ids back against input rows
  can rely on the ordering.
  """
  @spec insert_raw_all([map()]) :: {:ok, [integer()]}
  def insert_raw_all(rows) do
    now = DateTime.utc_now()
    {skipped, kept} = Enum.split_with(rows, &binary?/1)

    Enum.each(skipped, &log_skip/1)

    entries = Enum.map(kept, &entry(&1, now))

    Repo.transaction(fn -> insert_batches(entries) end)
  end

  defp insert_batches(entries) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.map(fn batch ->
      {_count, rows} = Repo.insert_all(PendingChunk, batch, returning: [:id])
      Enum.map(rows, & &1.id)
    end)
    |> List.flatten()
  end

  defp insert_batch_size,
    do: Application.get_env(:retrieval_node, :insert_raw_batch_size, @insert_batch_size)

  defp binary?(attrs), do: Chunking.binary_content?(Map.get(attrs, :raw_content) || "")

  defp log_skip(attrs) do
    Logger.info(
      "skipping binary content, not staged: natural_key=#{inspect(Map.get(attrs, :natural_key))}"
    )
  end

  defp entry(attrs, now) do
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
