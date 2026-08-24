defmodule RetrievalNode.Reranking do
  @moduledoc """
  Behaviour + dispatcher for the swappable cross-encoder reranking seam.

  Resolves the configured implementation (`:reranking_impl`) at call time and
  delegates to it, so call sites (query-time top-K candidate reranking) never
  name a concrete impl. Implementations:

    * `RetrievalNode.Reranking.NxServingImpl` — the v1 default: in-process
      Bumblebee/Nx.Serving cross-encoder over
      cross-encoder/ms-marco-MiniLM-L-6-v2.

  Scores are raw, unnormalized cross-encoder logits — higher means more
  relevant — one per passage, in input order. This module does not sort,
  threshold, or normalize; callers do that with the scores as returned.
  """

  @doc """
  Score each passage's relevance to `query`. Returns one raw (unnormalized)
  logit per passage, in input order — higher means more relevant.
  """
  @callback rerank_scores(query :: String.t(), passages :: [String.t()]) :: [float()]

  @doc """
  The configured reranking implementation module.

  Raises a clear `ArgumentError` if the configured `:reranking_impl` module
  isn't loaded (a misconfiguration), rather than letting call sites hit a
  cryptic `UndefinedFunctionError`.
  """
  @spec impl() :: module()
  def impl do
    mod = Application.fetch_env!(:retrieval_node, :reranking_impl)

    unless Code.ensure_loaded?(mod) do
      raise ArgumentError,
            "configured :reranking_impl #{inspect(mod)} is not loaded — check that " <>
              ":reranking_impl points at a compiled module."
    end

    mod
  end

  @doc "Score each passage's relevance to `query`, one raw logit per passage, in order."
  @spec rerank_scores(String.t(), [String.t()]) :: [float()]
  def rerank_scores(query, passages), do: impl().rerank_scores(query, passages)
end
