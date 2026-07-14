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

  @doc """
  The configured embedding implementation module.

  Raises a clear `ArgumentError` if the configured module isn't loaded — the
  concrete implementations (`NxServingImpl`, `LlamaCppSidecarImpl`) land in
  Phase 3, so until then callers should pass a precomputed vector via the
  `:embedding` option (e.g. `Search.hybrid_search(query, embedding: vec)`) rather
  than hit a cryptic `UndefinedFunctionError`.
  """
  @spec impl() :: module()
  def impl do
    mod = Application.fetch_env!(:retrieval_node, :embedding_impl)

    unless Code.ensure_loaded?(mod) do
      raise ArgumentError,
            "configured :embedding_impl #{inspect(mod)} is not available yet " <>
              "(embedding implementations land in Phase 3). Until then, pass a " <>
              "precomputed vector via the :embedding option."
    end

    mod
  end

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
