defmodule RetrievalNode.Reranking.StubImpl do
  @moduledoc """
  Deterministic, model-free reranking implementation for tests. Lets any
  reranking-dependent code (query-time top-K reranking) run without loading
  the cross-encoder model or EXLA. Scores are a stable function of the
  `{query, passage}` pair (so a test can assert two identical pairs score
  identically, and distinct passages score distinctly).
  """
  @behaviour RetrievalNode.Reranking

  @impl true
  def rerank_scores(query, passages) when is_binary(query) and is_list(passages) do
    Enum.map(passages, fn passage ->
      :erlang.phash2({query, passage}, 1000) / 100 - 5.0
    end)
  end
end
