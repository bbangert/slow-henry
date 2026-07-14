defmodule RetrievalNode.Embedding do
  @moduledoc """
  Dispatcher for the swappable embedding seam.

  Resolves the configured implementation (`:embedding_impl`) at call time and
  delegates to it, so call sites (query-time search, bulk indexing) never name a
  concrete impl. The behaviour callbacks and the concrete implementations
  (`NxServingImpl`, `LlamaCppSidecarImpl`) are fleshed out in Phase 3 — this
  module currently provides only the runtime dispatch that Phase 2's
  `Search.hybrid_search/2` needs.
  """

  @doc "The configured embedding implementation module."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:retrieval_node, :embedding_impl)

  @doc "Embed a single text into a 384-dim vector (list of floats)."
  @spec embed(String.t()) :: [float()]
  def embed(text), do: impl().embed(text)

  @doc "Embed a batch of texts into 384-dim vectors."
  @spec embed_batch([String.t()]) :: [[float()]]
  def embed_batch(texts), do: impl().embed_batch(texts)

  @doc "Embedding dimensionality (384 after Matryoshka truncation)."
  @spec dimensions() :: pos_integer()
  def dimensions, do: impl().dimensions()
end
