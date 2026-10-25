defmodule Mix.Tasks.Rn.Bench do
  @shortdoc "Runs the retrieval quality/latency/throughput benchmark harness"

  @moduledoc """
  Phase 9 benchmark harness (`embedding-model.md` protocol). Loads the labeled
  query set (`priv/bench/queries.jsonl` by default — see `priv/bench/README.md`
  for the matcher format and `RetrievalNode.Bench.Runner` for the orchestration),
  runs `Search.hybrid_search/2` per query, and prints a report against the four
  v1-launch targets:

    * nDCG@10 (mean over scorable queries)          >= 0.55
    * Query latency p99                             <= 300 ms
    * Embed throughput                               >= 10 passages/s
    * RAM peak (OS VmHWM)                            <= 1.5 GB

  Plus a fifth, best-effort section: Matryoshka truncation stability (see the
  "Matryoshka" section below — it is **not** the same thing as the protocol's
  384-vs-768 corpus quality delta; that number isn't computable without
  re-embedding the corpus at 768 dims, which is out of scope here).

  ## Numbers get tuned later

  The plan is explicit that this task is about the harness *existing and
  measuring correctly* — pass/fail against the targets above is informative,
  not a release gate, until the seed corpus and query set both grow past their
  Phase 9 thin-slice size (15 starter queries, one git repo).

  ## Graceful skips

  Every section independently degrades to a `SKIPPED` row with a reason
  instead of raising, when its precondition isn't met:

    * empty corpus (`chunks` table has 0 rows) — nothing to search yet.
    * embedding serving not warmed (`RetrievalNode.Embedding.Serving.ready?/0`
      false, only relevant when `NxServingImpl` is configured) — the harness
      cannot embed a query without a warm model, so it can't do anything
      besides report that. Run inside a dev/prod boot where the serving has
      finished warmup (check `/healthz`'s `embedding_warm` gate).
    * Matryoshka stability additionally requires `NxServingImpl` specifically
      (not `StubImpl`, which has no truncation step to probe).

  ## Options

    * `--queries PATH` — JSONL query file (default `priv/bench/queries.jsonl`)
    * `--top-k N` — result count for `Search.hybrid_search/2` and the nDCG@k
      cutoff (default 10)
    * `--skip-embed-probe` — skip the throughput/RAM probe (it embeds a batch
      of synthetic passages, which costs real inference time)
  """

  use Mix.Task

  alias RetrievalNode.Bench.{RerankEval, Runner}

  # run/1 ends in System.halt/1 (ensure_all_started boots the full supervision
  # tree, which would otherwise keep the VM alive after the report prints), so
  # it genuinely never returns — the spec tells dialyzer that's intentional.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    # This task is routinely pointed at the dev database while the dev server
    # is running. Booting the full tree with Oban's queues/plugins or ingest
    # owners would make this VM a second writer (Oban's notifier is
    # cluster-wide over the shared DB), so neither is started; the endpoint
    # does not bind a port without PHX_SERVER. Only Repo, Search and the
    # embedding/reranking servings are needed.
    Application.put_env(
      :retrieval_node,
      Oban,
      admin_oban_config(Application.get_env(:retrieval_node, Oban, []))
    )

    Application.put_env(:retrieval_node, :ingest_resume_on_boot, false)
    {:ok, _} = Application.ensure_all_started(:retrieval_node)

    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [queries: :string, top_k: :integer, skip_embed_probe: :boolean]
      )

    await_readiness(System.monotonic_time(:millisecond))

    run_opts =
      [
        queries_path: opts[:queries],
        top_k: opts[:top_k],
        skip_embed_probe: opts[:skip_embed_probe]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    result = Runner.run(run_opts)

    Mix.shell().info("\nBenchmark ran #{result.queries_loaded} queries from the query set.\n")
    print_quality(result.quality)
    print_embed_probe(result.embed_probe)
    print_matryoshka(result.matryoshka)

    # Application.ensure_all_started/1 above brings up the *entire* supervision
    # tree (Endpoint, Oban, the embedding Serving/Warmer sub-tree, ...) since
    # the harness needs Repo/Search/Embedding live — none of which has a
    # reason to keep running once the report is printed. Without an explicit
    # halt, `mix rn.bench` would hang after printing (a script/CI invocation
    # would need to be killed rather than exiting on its own).
    System.halt(0)
  end

  @doc false
  # Oban config for a VM that may insert jobs but must never run or schedule
  # any: no queues, no plugins (Cron/Pruner/Lifeline), and no peer, so it can't
  # take leadership from the dev node's plugins. `queues: []` (not `false`)
  # is what `Ingest.Supervisor.running_ingest_queues?/0` reads as "not an
  # ingest VM".
  @spec admin_oban_config(keyword()) :: keyword()
  def admin_oban_config(oban_config) do
    Keyword.merge(oban_config, queues: [], plugins: [], peer: false)
  end

  # A fresh VM boots with cold servings (model load + JIT), and the runner
  # reports SKIPPED rather than waiting, so poll for readiness first.
  @poll_interval_ms 1_000
  @poll_timeout_ms 180_000

  defp await_readiness(started_at) do
    ready? = Runner.embedding_ready?() and RerankEval.reranking_ready?()

    cond do
      ready? ->
        :ok

      System.monotonic_time(:millisecond) - started_at > @poll_timeout_ms ->
        :ok

      true ->
        Process.sleep(@poll_interval_ms)
        await_readiness(started_at)
    end
  end

  # -- Quality: nDCG@10 + latency percentiles --------------------------------

  defp print_quality({:skipped, reason}) do
    print_table([
      row("nDCG@10 (mean)", "SKIPPED", ">= 0.55", reason),
      row("Query latency p99", "SKIPPED", "<= 300 ms", reason)
    ])
  end

  defp print_quality({:ok, q}) do
    ndcg_status = pass_fail(q.mean_ndcg_at_k, &(&1 >= 0.55))
    p99 = q.latency_ms_percentiles[99]
    p99_status = pass_fail(p99, &(&1 <= 300))

    unresolved_note =
      if q.queries_unresolved > 0 do
        " (#{q.queries_unresolved}/#{q.queries_total} queries had no matcher hits in the " <>
          "corpus — excluded from the aggregate; ingest the sources their matchers point at)"
      else
        ""
      end

    print_table([
      row(
        "nDCG@10 (mean, n=#{q.queries_resolved})",
        ndcg_status,
        ">= 0.55",
        format_num(q.mean_ndcg_at_k) <> unresolved_note
      ),
      row(
        "nDCG@10 (mean over ALL, unresolvable = 0, n=#{q.queries_total})",
        "INFO",
        "comparable across corpora",
        format_num(q.mean_ndcg_all)
      ),
      row(
        "Query latency p50/p95/p99",
        p99_status,
        "p99 <= 300 ms",
        "#{format_num(q.latency_ms_percentiles[50])} / " <>
          "#{format_num(q.latency_ms_percentiles[95])} / #{format_num(p99)} ms"
      )
    ])

    print_per_query(q.per_query)
  end

  # One line per query: index, nDCG (or "-" when no corpus chunk matches its
  # matchers), rank of the first relevant hit in the top-k, and the query text.
  defp print_per_query(per_query) do
    Mix.shell().info("\n  #    nDCG   rank  query")

    per_query
    |> Enum.with_index(1)
    |> Enum.each(fn {q, i} ->
      ndcg = if q.resolvable, do: format_num(q.ndcg), else: "-"
      rank = if q.best_rank, do: Integer.to_string(q.best_rank), else: "-"

      Mix.shell().info(
        "  #{String.pad_leading(Integer.to_string(i), 2)}  " <>
          "#{String.pad_leading(ndcg, 6)}  #{String.pad_leading(rank, 4)}  " <>
          String.slice(q.query, 0, 70)
      )
    end)

    Mix.shell().info("")
  end

  # -- Embed throughput + RAM --------------------------------------------------

  defp print_embed_probe({:skipped, reason}) do
    print_table([
      row("Embed throughput", "SKIPPED", ">= 10 passages/s", reason),
      row("RAM peak (OS VmHWM)", "SKIPPED", "<= 1.5 GB", reason)
    ])
  end

  defp print_embed_probe({:ok, p}) do
    throughput_status = pass_fail(p.throughput_passages_per_sec, &(&1 >= 10))
    ram_mb = p.ram.os_vm_hwm_after_mb
    ram_status = pass_fail(ram_mb, &(&1 <= 1536))

    ram_detail =
      if ram_mb do
        "#{format_num(ram_mb)} MB (erlang total delta: " <>
          "#{format_num(p.ram.erlang_total_delta_mb)} MB)"
      else
        "OS VmHWM unavailable (non-Linux?) — erlang total delta: " <>
          "#{format_num(p.ram.erlang_total_delta_mb)} MB"
      end

    print_table([
      row(
        "Embed throughput (n=#{p.passages})",
        throughput_status,
        ">= 10 passages/s",
        format_num(p.throughput_passages_per_sec) <> " passages/s"
      ),
      row("RAM peak (OS VmHWM)", ram_status, "<= 1.5 GB", ram_detail)
    ])
  end

  # -- Matryoshka stability (proxy, always SKIPPED against the real target) --

  defp print_matryoshka({:skipped, reason}) do
    print_table([row("Matryoshka 384-vs-768 delta", "SKIPPED", "< 2%", reason)])
  end

  defp print_matryoshka({:ok, m}) do
    print_table([
      row(
        "Matryoshka truncation stability (proxy, n=#{m.queries_scored})",
        "SKIPPED",
        "< 2% (unmeasurable — see note)",
        "stability_delta=#{format_num(m.mean_stability_delta)} " <>
          "overlap@k=#{format_num(m.mean_overlap_at_k)}"
      )
    ])

    Mix.shell().info(m.note <> "\n")
  end

  # -- table rendering --------------------------------------------------------

  defp row(metric, status, target, detail), do: {metric, status, target, detail}

  defp pass_fail(nil, _f), do: "SKIPPED"
  defp pass_fail(value, f), do: if(f.(value), do: "PASS", else: "FAIL")

  defp format_num(nil), do: "n/a"
  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp format_num(n), do: to_string(n)

  defp print_table(rows) do
    Enum.each(rows, fn {metric, status, target, detail} ->
      Mix.shell().info("  #{pad(metric, 42)} #{pad(status, 8)} #{pad(target, 24)} #{detail}")
    end)

    Mix.shell().info("")
  end

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)
end
