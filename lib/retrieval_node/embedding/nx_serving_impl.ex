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

  @doc false
  # Bench-only seam (RetrievalNode.Bench.Runner's Matryoshka stability probe):
  # returns the untruncated, L2-normalized 768-dim serving output, bypassing the
  # truncation `embed/1` always applies. No other caller should reach for this —
  # every stored/query vector in the system is 384-dim by design (see
  # `Embedding.vector` typedoc); this exists only so the bench harness can
  # reconstruct a 384-dim vector from the pre-truncation output and compare it
  # against `embed/1`'s normal-path output.
  @spec embed_full_dims(String.t()) :: [float()]
  def embed_full_dims(text) when is_binary(text) do
    [result] = Nx.Serving.batched_run(Serving.name(), [text])
    full_dims(result)
  end

  defp full_dims(%{embedding: tensor}), do: Nx.to_flat_list(tensor)

  @doc """
  Matryoshka post-processing: truncate a full-dimension embedding to the leading
  `#{@dimensions}` dims and L2-renormalize to unit length, returning a plain list
  of floats. Pure (no serving/model), so it is unit-testable in isolation.

  Raises if the input isn't a single pooled sentence embedding (a rank-1 tensor).
  A rank-2 tensor (sequence_length x hidden_size) means the serving is emitting
  unpooled per-token hidden states — e.g. `Serving.text_embedding/3` missing
  `output_pool: :mean_pooling` — and must fail loudly here rather than silently
  flattening into a many-thousand-float "vector" that corrupts every downstream
  pgvector write.
  """
  @spec matryoshka(%{embedding: Nx.Tensor.t()} | Nx.Tensor.t()) :: [float()]
  def matryoshka(%{embedding: tensor}), do: matryoshka(tensor)

  def matryoshka(%Nx.Tensor{shape: shape}) when tuple_size(shape) != 1 do
    raise "expected a pooled 1-D sentence embedding, got tensor of shape " <>
            "#{inspect(shape)} — the serving is likely missing " <>
            "`output_pool: :mean_pooling` (RetrievalNode.Embedding.Serving)"
  end

  def matryoshka(%Nx.Tensor{shape: {dims}}) when dims < @dimensions do
    raise "expected a pooled sentence embedding with at least #{@dimensions} dims, " <>
            "got #{dims} — the serving is likely misconfigured " <>
            "(RetrievalNode.Embedding.Serving)"
  end

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
