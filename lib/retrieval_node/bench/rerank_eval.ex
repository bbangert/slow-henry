defmodule RetrievalNode.Bench.RerankEval do
  @moduledoc """
  Plan 1.4 reranker eval: compares `Search.hybrid_search/2` with `rerank:
  false` (plain RRF fusion) against `rerank: true` (cross-encoder rerank of
  the top-50 RRF candidates) over the shared labeled query set, reporting
  MRR, Hit@1, Hit@5, and latency p50/p95 per mode.

  Reuses `RetrievalNode.Bench.Runner`'s query loading/matcher-resolution/
  precondition machinery rather than duplicating it — this module only adds
  the two-mode comparison and the MRR/Hit@k scoring that `mix rn.bench`
  doesn't need (it only ever runs one mode). Same `{:ok, ...} | {:skipped,
  reason}` convention as `Runner`: this always completes rather than raising
  when a precondition (empty corpus, unwarmed embedding/reranking serving)
  isn't met.

  This module only computes and returns a plain map — no printing. `mix
  rn.rerank_eval` (`Mix.Tasks.Rn.RerankEval`) is the report layer.
  """

  alias RetrievalNode.Bench.{Metrics, Runner}
  alias RetrievalNode.Reranking
  alias RetrievalNode.Reranking.{NxServingImpl, Serving}
  alias RetrievalNode.Search
  alias RetrievalNode.Search.HybridQuery

  @default_queries_path "priv/bench/queries.jsonl"
  @modes [false, true]

  @type section :: {:ok, map()} | {:skipped, String.t()}

  @doc """
  Run the eval. Options:

    * `:queries_path` — JSONL query file (default `#{@default_queries_path}`,
      the same shared query set `mix rn.bench` uses)
    * `:top_k` — result count for `Search.hybrid_search/2` and the MRR/Hit@k
      cutoff (default 10). Normalized once via `HybridQuery.clamp_top_k/1`
      before either mode runs, and the NORMALIZED value (not the raw option)
      is what `:top_k` in the returned result reports — both modes are
      measured at the same clamped cutoff, so the report describes what was
      actually run (a caller-supplied 0 measures at the clamp's default 20,
      not "0"; a caller-supplied 1_000 measures at the clamp's max 100, not
      "1000" — either raw value in the report would misdescribe Hit@5 in
      particular).

  Returns `{:ok, result}` or `{:skipped, reason}` — never raises for an unmet
  precondition (empty corpus, unwarmed embedding serving, unwarmed reranking
  serving).
  """
  @spec run(keyword()) :: section
  def run(opts \\ []) do
    queries_path = Keyword.get(opts, :queries_path, @default_queries_path)
    top_k = opts |> Keyword.get(:top_k, 10) |> HybridQuery.clamp_top_k()

    cond do
      not Runner.corpus_seeded?() ->
        {:skipped,
         "corpus not seeded — ingest at least one source before running mix rn.rerank_eval"}

      not Runner.embedding_ready?() ->
        {:skipped, "requires warmed embedding serving; run inside dev with serving enabled"}

      not reranking_ready?() ->
        {:skipped, "requires warmed reranking serving; run inside dev with serving enabled"}

      true ->
        {:ok, run_eval(queries_path, top_k)}
    end
  end

  @doc """
  Whether the configured reranking implementation is ready to score. Mirrors
  `Runner.embedding_ready?/0`: the real `NxServingImpl` needs
  `Reranking.Serving.ready?/0` (post-warmup); any other configured impl
  (e.g. the test-env `StubImpl`) has no warmup concept and is always
  considered ready.
  """
  @spec reranking_ready? :: boolean()
  def reranking_ready? do
    case Reranking.impl() do
      NxServingImpl -> Serving.ready?()
      _other -> true
    end
  end

  defp run_eval(queries_path, top_k) do
    queries = Runner.load_queries!(queries_path)
    per_query = Enum.map(queries, &score_query(&1, top_k))

    resolved = Enum.filter(per_query, & &1.resolvable)

    %{
      queries_total: length(per_query),
      queries_resolved: length(resolved),
      queries_unresolved: length(per_query) - length(resolved),
      top_k: top_k,
      modes: Map.new(@modes, &{&1, aggregate_mode(resolved, &1)}),
      per_query: per_query
    }
  end

  defp score_query(%{"query" => text} = q, top_k) do
    relevant_ids = Runner.resolve_relevant_ids(q["relevant"])

    if MapSet.size(relevant_ids) == 0 do
      %{query: text, note: q["note"], resolvable: false, modes: %{}}
    else
      modes = Map.new(@modes, &{&1, score_mode(text, relevant_ids, &1, top_k)})
      %{query: text, note: q["note"], resolvable: true, modes: modes}
    end
  end

  defp score_mode(text, relevant_ids, rerank?, top_k) do
    {elapsed_us, hits} =
      :timer.tc(fn -> Search.hybrid_search(text, top_k: top_k, rerank: rerank?) end)

    ranked_ids = Enum.map(hits, & &1.chunk.id)
    mrr = Metrics.mrr(ranked_ids, relevant_ids)

    %{
      mrr: mrr,
      hit_at_1: Metrics.hit_at_k(ranked_ids, relevant_ids, 1),
      hit_at_5: Metrics.hit_at_k(ranked_ids, relevant_ids, 5),
      first_relevant_rank: first_relevant_rank(ranked_ids, relevant_ids),
      latency_ms: elapsed_us / 1000
    }
  end

  defp first_relevant_rank(ranked_ids, relevant_ids) do
    ranked_ids
    |> Enum.with_index(1)
    |> Enum.find(fn {id, _rank} -> MapSet.member?(relevant_ids, id) end)
    |> case do
      {_id, rank} -> rank
      nil -> nil
    end
  end

  defp aggregate_mode(resolved, rerank?) do
    scores = Enum.map(resolved, &Map.fetch!(&1.modes, rerank?))
    latencies = Enum.map(scores, & &1.latency_ms)

    %{
      mean_mrr: mean(Enum.map(scores, & &1.mrr)),
      hit_at_1_rate: mean(Enum.map(scores, &bool_to_num(&1.hit_at_1))),
      hit_at_5_rate: mean(Enum.map(scores, &bool_to_num(&1.hit_at_5))),
      latency_ms_percentiles: Metrics.percentiles(latencies, [50, 95])
    }
  end

  defp bool_to_num(true), do: 1.0
  defp bool_to_num(false), do: 0.0

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
