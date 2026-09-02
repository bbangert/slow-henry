defmodule RetrievalNode.Ingest.Workers.EmbedBatch do
  @moduledoc """
  Embeds a batch of staged chunk rows and enqueues the terminal upsert. The chunk
  text is prefixed with its context breadcrumb before embedding, so the vector
  captures where the chunk lives (see `Chunking.Breadcrumb`).

  Runs on the concurrency-1 `:embed` queue — one Nx.Serving, protecting the MCP
  endpoint from bulk-indexing CPU contention.

  Forwards `raw_pending_chunk_id` (the raw staging row's own id — see
  `Ingest.Workers.ChunkFiles`) straight through to `UpsertChunks` untouched, when
  present — `UpsertChunks` is the pipeline's single terminal stage and needs it to
  find a file's identity/generation for a zero-chunk batch (see its moduledoc).
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3,
    unique: [
      period: {1, :hour},
      keys: [:pending_chunk_ids],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Chunking.Breadcrumb
  alias RetrievalNode.Embedding
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Ingest.Workers.UpsertChunks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids} = args}) do
    rows = PendingChunks.fetch_many!(ids)
    vectors = rows |> Enum.map(&embed_text/1) |> Embedding.embed_batch()

    # Fail loud (→ Oban retry) rather than let Enum.zip silently drop the tail if
    # the serving ever returns fewer vectors than rows — a truncated zip would
    # strand those chunk rows unembedded with no error surfaced.
    if length(vectors) != length(rows) do
      raise "embed_batch returned #{length(vectors)} vectors for #{length(rows)} rows"
    end

    pairs =
      rows
      |> Enum.zip(vectors)
      |> Enum.map(fn {row, vector} -> %{id: row.id, embedding: vector} end)

    upsert_args =
      case Map.get(args, "raw_pending_chunk_id") do
        nil -> %{"pending_chunk_ids" => ids}
        raw_id -> %{"pending_chunk_ids" => ids, "raw_pending_chunk_id" => raw_id}
      end

    with {:ok, _} <- PendingChunks.set_embeddings(pairs),
         {:ok, _job} <- Oban.insert(UpsertChunks.new(upsert_args)) do
      :ok
    end
  end

  defp embed_text(%{context_breadcrumb: crumb, chunk_content: content})
       when crumb in [nil, ""],
       do: content

  defp embed_text(%{context_breadcrumb: crumb, chunk_content: content}),
    do: Breadcrumb.prepend(crumb, content)
end
