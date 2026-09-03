defmodule RetrievalNode.SearchTest do
  # async: false — mutates the GLOBAL :reranking_impl app env (same reason as
  # RetrievalNode.RerankingTest); under async a concurrent test could read the
  # test double during that window.
  use ExUnit.Case, async: false

  alias RetrievalNode.Search

  # `Search.score_and_rank/4` is the pure tail of the `rerank: true` funnel in
  # `hybrid_search/2` — everything after candidate content has been fetched
  # and filtered down to the rows whose content row still exists. Exercising
  # the "every candidate's content vanished between the HybridQuery read and
  # the content fetch" scenario through the public API would mean racing a
  # concurrent delete against `rerank_hits/3`'s own Repo call — not reliably
  # reproducible from a test. `score_and_rank/4` is public (not `defp`) and
  # `@doc false` purely so this module can call it directly instead (see its
  # doc comment in lib/retrieval_node/search.ex).
  defmodule RaisingOnEmptyReranking do
    @moduledoc false
    @behaviour RetrievalNode.Reranking

    @impl true
    def rerank_scores(_query, []),
      do: raise("rerank_scores/2 called with an empty passage list")

    def rerank_scores(_query, passages), do: Enum.map(passages, fn _ -> 1.0 end)
  end

  defp row_fixture(fused_score \\ 0.5) do
    %{
      chunk_id: Ecto.UUID.generate(),
      source_type: "git_repo",
      repo: "repo-a",
      lang: "elixir",
      context_breadcrumb: "lib/foo.ex",
      metadata: %{},
      fused_score: fused_score
    }
  end

  setup do
    original = Application.fetch_env!(:retrieval_node, :reranking_impl)
    Application.put_env(:retrieval_node, :reranking_impl, RaisingOnEmptyReranking)
    on_exit(fn -> Application.put_env(:retrieval_node, :reranking_impl, original) end)
    :ok
  end

  describe "score_and_rank/4" do
    test "returns [] without calling the reranker when every candidate's content vanished" do
      # `rows` is non-empty (as it always is at the real call site — rows and
      # contents are built together by Enum.unzip, so they're the same
      # length) to prove the branch taken is keyed on `contents == []`, not
      # merely on an empty `rows`. If the guard were removed, this would
      # raise via RaisingOnEmptyReranking instead of returning [].
      assert Search.score_and_rank("query", [row_fixture()], [], 5) == []
    end

    test "still reranks when contents is non-empty" do
      row = row_fixture(0.1)

      assert [%{score: 1.0, fused_score: 0.1, chunk: %{id: chunk_id}}] =
               Search.score_and_rank("query", [row], ["some content"], 5)

      assert chunk_id == row.chunk_id
    end
  end
end
