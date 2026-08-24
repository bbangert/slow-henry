defmodule RetrievalNode.Bench.Metrics do
  @moduledoc """
  Pure math for the benchmark harness: nDCG@k (binary relevance) and latency
  percentiles. No Repo/Embedding/Search dependency, so these are plain unit
  tests with hand-computed expected values — the harness's correctness rests on
  this module being right, everything else in `Bench` is orchestration around it.
  """

  @doc """
  Normalized Discounted Cumulative Gain at rank `k`, binary relevance (a chunk
  is either relevant or it isn't — the query-set matcher shape has no graded
  relevance levels).

  `ranked_ids` is the result list in rank order (best first); `relevant_ids` is
  a `MapSet` of the ids considered relevant for this query. Only the leading
  `k` of `ranked_ids` count toward DCG, matching the standard nDCG@k
  definition.

  Returns `0.0` when `relevant_ids` is empty — there is no ideal ranking to
  normalize against, so by convention this is treated as a perfect-recall
  no-op rather than raised. Callers that want to distinguish "no relevant docs
  known" from "scored 0" should check `MapSet.size(relevant_ids) == 0`
  themselves before calling (the `Bench.Runner` does, to exclude unresolved
  queries from the aggregate rather than silently zero-scoring them).
  """
  @spec ndcg_at_k([term()], MapSet.t(), pos_integer()) :: float()
  def ndcg_at_k(ranked_ids, relevant_ids, k) when is_list(ranked_ids) and is_integer(k) do
    if MapSet.size(relevant_ids) == 0 do
      0.0
    else
      dcg = dcg_at_k(ranked_ids, relevant_ids, k)
      idcg = ideal_dcg_at_k(MapSet.size(relevant_ids), k)

      if idcg == 0.0, do: 0.0, else: dcg / idcg
    end
  end

  defp dcg_at_k(ranked_ids, relevant_ids, k) do
    ranked_ids
    |> Enum.take(k)
    |> Enum.with_index(1)
    |> Enum.reduce(0.0, fn {id, rank}, acc ->
      gain = if MapSet.member?(relevant_ids, id), do: 1.0, else: 0.0
      acc + gain / :math.log2(rank + 1)
    end)
  end

  # The ideal ranking puts every relevant doc first, so IDCG@k sums 1/log2(i+1)
  # over the first min(relevant_count, k) ranks.
  defp ideal_dcg_at_k(relevant_count, k) do
    1..min(relevant_count, k)
    |> Enum.reduce(0.0, fn rank, acc -> acc + 1.0 / :math.log2(rank + 1) end)
  end

  @doc """
  Mean Reciprocal Rank: `1.0 / rank` of the first relevant id in `ranked_ids`
  (1-indexed), or `0.0` if no relevant id appears anywhere in `ranked_ids`.

  Same convention as `ndcg_at_k/3`: `relevant_ids` is a `MapSet`, and an empty
  `relevant_ids` scores `0.0` rather than raising (callers exclude unresolved
  queries from the aggregate themselves, same as `Bench.Runner` does for
  nDCG).
  """
  @spec mrr([term()], MapSet.t()) :: float()
  def mrr(ranked_ids, relevant_ids) when is_list(ranked_ids) do
    if MapSet.size(relevant_ids) == 0 do
      0.0
    else
      ranked_ids
      |> Enum.with_index(1)
      |> Enum.find(fn {id, _rank} -> MapSet.member?(relevant_ids, id) end)
      |> case do
        {_id, rank} -> 1.0 / rank
        nil -> 0.0
      end
    end
  end

  @doc """
  Whether any of the leading `k` ids in `ranked_ids` is relevant — a boolean
  "did we get a hit within the top k" check, as opposed to `ndcg_at_k/3`'s
  graded score. Same `MapSet`/empty-`relevant_ids` convention as `mrr/2` and
  `ndcg_at_k/3`: an empty `relevant_ids` is `false` (nothing to hit).
  """
  @spec hit_at_k([term()], MapSet.t(), pos_integer()) :: boolean()
  def hit_at_k(ranked_ids, relevant_ids, k) when is_list(ranked_ids) and is_integer(k) do
    ranked_ids
    |> Enum.take(k)
    |> Enum.any?(&MapSet.member?(relevant_ids, &1))
  end

  @doc """
  Percentile of `values` via the nearest-rank method: sort ascending, then
  `rank = ceil(p/100 * n)` (clamped to `[1, n]`), value = the element at that
  1-indexed rank. Simple, deterministic, no interpolation — adequate for a
  benchmark report where the sample sizes are small (tens to low hundreds of
  queries).

  Returns `nil` for an empty list (nothing to report rather than a crash — the
  harness hits this when zero queries were scorable).
  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _p), do: nil

  def percentile(values, p) when is_list(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = (p / 100 * n) |> Float.ceil() |> trunc() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end

  @doc "Compute multiple percentiles at once. Returns `%{p => value}` for each `p` in `ps`."
  @spec percentiles([number()], [number()]) :: %{number() => number() | nil}
  def percentiles(values, ps) when is_list(values) and is_list(ps) do
    Map.new(ps, fn p -> {p, percentile(values, p)} end)
  end
end
