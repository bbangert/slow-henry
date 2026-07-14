defmodule RetrievalNode.Ingest.Workers.EmbedBatch do
  @moduledoc """
  Embeds a batch of staged chunk rows and enqueues the terminal upsert. The chunk
  text is prefixed with its context breadcrumb before embedding, so the vector
  captures where the chunk lives (see `Chunking.Breadcrumb`).

  Runs on the concurrency-1 `:embed` queue — one Nx.Serving, protecting the MCP
  endpoint from bulk-indexing CPU contention.
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
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids}}) do
    rows = PendingChunks.fetch_many!(ids)
    vectors = rows |> Enum.map(&embed_text/1) |> Embedding.embed_batch()

    pairs =
      rows
      |> Enum.zip(vectors)
      |> Enum.map(fn {row, vector} -> %{id: row.id, embedding: vector} end)

    with {:ok, _} <- PendingChunks.set_embeddings(pairs),
         {:ok, _job} <- Oban.insert(UpsertChunks.new(%{"pending_chunk_ids" => ids})) do
      :ok
    end
  end

  defp embed_text(%{context_breadcrumb: crumb, chunk_content: content})
       when crumb in [nil, ""],
       do: content

  defp embed_text(%{context_breadcrumb: crumb, chunk_content: content}),
    do: Breadcrumb.prepend(crumb, content)
end
