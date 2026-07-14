defmodule RetrievalNode.Embedding.NxServingImpl do
  @moduledoc """
  Default embedding implementation: in-process Bumblebee/`Nx.Serving` over
  nomic-embed-text-v1.5.

  The serving (`RetrievalNode.Embedding.Serving`) produces full-dimension,
  L2-normalized hidden-state embeddings. This module applies **Matryoshka
  truncation** — keep the leading 384 dimensions, then L2-renormalize — so
  nothing downstream ever sees the full 768-dim vector. `embed/1` and
  `embed_batch/1` differ only in input arity; both go through the same serving so
  `Nx.Serving` can batch a query embed (batch of 1) alongside a bulk indexing
  batch (batch of N).
  """

  @behaviour RetrievalNode.Embedding

  alias RetrievalNode.Embedding.Serving

  # Matryoshka target dimensionality. nomic-embed-text-v1.5 is trained so the
  # leading dims remain meaningful after truncation; 384 halves storage/compute
  # versus the native 768 at a <2% retrieval-quality cost (validated in Phase 9).
  @dimensions 384

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def embed(text) when is_binary(text) do
    [vector] = embed_batch([text])
    vector
  end

  @impl true
  def embed_batch(texts) when is_list(texts) do
    # The input is always a list, so Bumblebee's serving always returns a list of
    # per-text `%{embedding: tensor}` results (never a bare single map).
    Serving.name()
    |> Nx.Serving.batched_run(texts)
    |> Enum.map(&matryoshka/1)
  end

  @doc """
  Matryoshka post-processing: truncate a full-dimension embedding to the leading
  `#{@dimensions}` dims and L2-renormalize to unit length, returning a plain list
  of floats. Pure (no serving/model), so it is unit-testable in isolation.
  """
  @spec matryoshka(%{embedding: Nx.Tensor.t()} | Nx.Tensor.t()) :: [float()]
  def matryoshka(%{embedding: tensor}), do: matryoshka(tensor)

  def matryoshka(%Nx.Tensor{} = tensor) do
    tensor
    |> Nx.slice_along_axis(0, @dimensions, axis: -1)
    |> l2_normalize()
    |> Nx.to_flat_list()
  end

  # Epsilon floor on the norm so an all-zero (truncated) vector normalizes to
  # zeros (finite) rather than NaN — a NaN embedding would silently poison
  # pgvector inserts/search. Real embeddings are never all-zero, so this only
  # ever affects the degenerate case.
  @norm_epsilon 1.0e-12

  defp l2_normalize(tensor) do
    norm =
      tensor
      |> Nx.pow(2)
      |> Nx.sum(axes: [-1], keep_axes: true)
      |> Nx.sqrt()
      |> Nx.max(@norm_epsilon)

    Nx.divide(tensor, norm)
  end
end
