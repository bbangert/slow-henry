defmodule RetrievalNode.Embedding.StubImpl do
  @moduledoc """
  Deterministic, model-free embedding implementation for tests. Lets the ingest
  pipeline (EmbedBatch) and any embedding-dependent code run without loading
  nomic-embed-text or EXLA. Vectors are a stable function of the input text (so
  a test can assert two identical texts embed identically) and 384-dim to match
  the real impl.
  """
  @behaviour RetrievalNode.Embedding

  @dimensions 384

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def embed(text) when is_binary(text) do
    for i <- 1..@dimensions, do: :math.sin(:erlang.phash2({text, i}) / 1_000_000)
  end

  @impl true
  def embed_batch(texts) when is_list(texts), do: Enum.map(texts, &embed/1)
end
