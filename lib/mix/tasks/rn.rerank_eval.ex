defmodule Mix.Tasks.Rn.RerankEval do
  @shortdoc "Compares hybrid_search/2 quality+latency with rerank on vs off (plan 1.4 gate)"

  @moduledoc """
  Plan 1.4 reranker eval. Runs `Search.hybrid_search/2` over the shared
  labeled query set (`priv/bench/queries.jsonl` by default — see
  `priv/bench/README.md`) once with `rerank: false` and once with `rerank:
  true` per query, and reports MRR, Hit@1, Hit@5, and latency p50/p95 per
  mode plus a gate verdict:

    * rerank wins  — mean MRR and Hit@1 rate both improve under rerank
    * p95 budget   — reranked p95 latency <= 300 ms

  Both must hold for the gate to recommend flipping `:rerank_default` to
  `true` in config.

  ## Graceful skips

  Same convention as `mix rn.bench`: the eval degrades to a `SKIPPED` report
  with a reason instead of raising when its precondition isn't met — empty
  corpus, unwarmed embedding serving, or unwarmed reranking serving (only
  relevant when `NxServingImpl` is configured for either).

  ## Options

    * `--queries PATH` — JSONL query file (default `priv/bench/queries.jsonl`)
    * `--top-k N` — result count for `Search.hybrid_search/2` and the MRR/Hit@k
      cutoff (default 10)
  """

  use Mix.Task

  alias RetrievalNode.Bench.{RerankEval, Runner}

  @p95_budget_ms 300

  # run/1 ends in System.halt/1 (ensure_all_started boots the full supervision
  # tree, which would otherwise keep the VM alive after the report prints), so
  # it genuinely never returns — the spec tells dialyzer that's intentional.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    # This VM boots with its normal (non-empty) Oban queues config, so
    # Ingest.Supervisor would otherwise start Ingest.SourceOwner processes —
    # this task has no reason to become a second writer for a source the dev
    # server already owns.
    Application.put_env(:retrieval_node, :ingest_resume_on_boot, false)
    {:ok, _} = Application.ensure_all_started(:retrieval_node)

    # This node's cron-driven sync jobs (RepoSync/JiraSync/DriveSync, plus
    # embed/reindex workers they enqueue) must not compete with the model
    # processes for CPU/GPU while we're measuring latency. `local_only:` is
    # load-bearing: the default broadcasts the pause through the shared-DB
    # notifier to EVERY connected node — it would silently pause the long-lived
    # dev server's queues too, and they'd stay paused until that node restarts.
    Oban.pause_all_queues(local_only: true)

    {opts, _rest} =
      OptionParser.parse!(args, strict: [queries: :string, top_k: :integer])

    await_readiness()

    run_opts =
      [queries_path: opts[:queries], top_k: opts[:top_k]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    result = RerankEval.run(run_opts)

    print_report(result)

    # Application.ensure_all_started/1 above brings up the *entire* supervision
    # tree (Endpoint, Oban, the embedding/reranking Serving/Warmer sub-trees,
    # ...) since the eval needs Repo/Search/Embedding/Reranking live — none of
    # which has a reason to keep running once the report is printed. Without
    # an explicit halt, `mix rn.rerank_eval` would hang after printing.
    System.halt(0)
  end

  # Mirrors mix rn.bench: it has no equivalent poll today (its embedding
  # serving is expected already-warm by the time someone runs it manually),
  # but this task additionally depends on the reranking serving, which can
  # legitimately still be JIT-compiling right after boot — so poll both
  # readiness flags for a bounded window rather than reporting a spurious
  # SKIPPED on a fresh `mix rn.rerank_eval` invocation.
  @poll_interval_ms 1_000
  @poll_timeout_ms 120_000

  defp await_readiness, do: await_readiness(System.monotonic_time(:millisecond))

  defp await_readiness(started_at) do
    embedding_ready? = Runner.embedding_ready?()
    reranking_ready? = RerankEval.reranking_ready?()

    cond do
      embedding_ready? and reranking_ready? ->
        :ok

      System.monotonic_time(:millisecond) - started_at > @poll_timeout_ms ->
        :ok

      true ->
        Process.sleep(@poll_interval_ms)
        await_readiness(started_at)
    end
  end

  # -- report rendering --------------------------------------------------------

  defp print_report({:skipped, reason}) do
    Mix.shell().info("\nReranker eval SKIPPED: #{reason}\n")
  end

  defp print_report({:ok, result}) do
    Mix.shell().info(
      "\nReranker eval ran #{result.queries_resolved}/#{result.queries_total} queries " <>
        "(top_k=#{result.top_k}); #{result.queries_unresolved} unresolved (excluded from aggregates).\n"
    )

    print_mode_table(result.modes)
    print_per_query_table(result.per_query)
    print_gate(result.modes)
  end

  defp print_mode_table(modes) do
    baseline = modes[false]
    reranked = modes[true]

    Mix.shell().info("Aggregate (mean over resolved queries):\n")

    Mix.shell().info(
      "  #{pad("mode", 10)} #{pad("MRR", 8)} #{pad("Hit@1", 8)} #{pad("Hit@5", 8)} " <>
        "#{pad("p50 ms", 10)} #{pad("p95 ms", 10)}"
    )

    Enum.each(
      [{"baseline", baseline}, {"reranked", reranked}],
      fn {label, m} ->
        p = m.latency_ms_percentiles

        Mix.shell().info(
          "  #{pad(label, 10)} #{pad(format_num(m.mean_mrr), 8)} " <>
            "#{pad(format_num(m.hit_at_1_rate), 8)} #{pad(format_num(m.hit_at_5_rate), 8)} " <>
            "#{pad(format_num(p[50]), 10)} #{pad(format_num(p[95]), 10)}"
        )
      end
    )

    Mix.shell().info("")
  end

  defp print_per_query_table(per_query) do
    Mix.shell().info("Per-query (baseline vs reranked MRR / first-relevant-rank / latency ms):\n")

    per_query
    |> Enum.filter(& &1.resolvable)
    |> Enum.each(fn %{query: query, modes: modes} ->
      base = modes[false]
      rerank = modes[true]

      Mix.shell().info("  #{query}")

      Mix.shell().info(
        "    baseline: mrr=#{format_num(base.mrr)} rank=#{format_rank(base.first_relevant_rank)} " <>
          "latency=#{format_num(base.latency_ms)}ms"
      )

      Mix.shell().info(
        "    reranked: mrr=#{format_num(rerank.mrr)} rank=#{format_rank(rerank.first_relevant_rank)} " <>
          "latency=#{format_num(rerank.latency_ms)}ms"
      )
    end)

    Mix.shell().info("")
  end

  defp print_gate(modes) do
    baseline = modes[false]
    reranked = modes[true]

    mrr_improved = gt(reranked.mean_mrr, baseline.mean_mrr)
    hit1_improved = gt(reranked.hit_at_1_rate, baseline.hit_at_1_rate)
    rerank_wins = mrr_improved and hit1_improved

    p95 = reranked.latency_ms_percentiles[95]
    within_budget = not is_nil(p95) and p95 <= @p95_budget_ms
    flip = rerank_wins and within_budget

    Mix.shell().info(
      "GATE (plan 1.4): rerank wins = #{rerank_wins} (MRR & Hit@1 improved), " <>
        "p95 = #{format_num(p95)}ms (budget #{@p95_budget_ms}ms) → flip rerank_default = #{flip}"
    )
  end

  defp gt(nil, _), do: false
  defp gt(_, nil), do: false
  defp gt(a, b), do: a > b

  defp format_rank(nil), do: "-"
  defp format_rank(rank), do: to_string(rank)

  defp format_num(nil), do: "n/a"
  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp format_num(n), do: to_string(n)

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)
end
