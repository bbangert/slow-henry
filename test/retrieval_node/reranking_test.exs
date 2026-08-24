defmodule RetrievalNode.RerankingTest do
  # async: false — the unloaded-impl test mutates the GLOBAL :reranking_impl
  # app env; under async a concurrent test (e.g. RerankEvalTest) can read the
  # bogus module during that window and fail seed-dependently.
  use ExUnit.Case, async: false

  alias RetrievalNode.Reranking

  describe "impl/0" do
    test "resolves the configured :reranking_impl" do
      assert Reranking.impl() == RetrievalNode.Reranking.StubImpl
    end

    test "raises ArgumentError when the configured impl module isn't loaded" do
      original = Application.fetch_env!(:retrieval_node, :reranking_impl)
      Application.put_env(:retrieval_node, :reranking_impl, RetrievalNode.Reranking.NoSuchImpl)

      on_exit(fn -> Application.put_env(:retrieval_node, :reranking_impl, original) end)

      assert_raise ArgumentError, ~r/is not loaded/, fn ->
        Reranking.impl()
      end
    end
  end

  describe "rerank_scores/2 (dispatched to StubImpl)" do
    test "returns one score per passage, in order" do
      scores = Reranking.rerank_scores("query", ["passage one", "passage two", "passage three"])

      assert length(scores) == 3
      assert Enum.all?(scores, &is_float/1)
    end

    test "is deterministic for the same {query, passage} pair" do
      scores_a = Reranking.rerank_scores("query", ["a passage"])
      scores_b = Reranking.rerank_scores("query", ["a passage"])

      assert scores_a == scores_b
    end

    test "distinct passages get distinct scores" do
      [score_a, score_b] = Reranking.rerank_scores("query", ["alpha", "totally different beta"])

      assert score_a != score_b
    end
  end
end
