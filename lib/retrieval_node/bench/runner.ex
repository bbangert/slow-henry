defmodule RetrievalNode.Bench.Runner do
  @moduledoc """
  Orchestrates the Phase 9 benchmark harness (`embedding-model.md` protocol):
  load a labeled query set, resolve each query's relevance matchers to chunk
  ids, run `Search.hybrid_search/2` and score nDCG@k + latency percentiles,
  probe embed throughput/RAM, and (when the real model is available) measure
  Matryoshka truncation stability.

  Touches `Repo` directly (matcher resolution needs to query `chunks`), which
  is otherwise reserved for `Ingest`/`Search` — `Bench` is a third, deliberate
  exception for the same reason those two are: it is a context with a genuine
  need to read the `chunks` table, not a caller reaching around a context
  boundary.

  Every section of the result degrades to `{:skipped, reason}` rather than
  raising when its preconditions aren't met (empty corpus, unwarmed serving,
  non-`NxServingImpl` configured), so `mix rn.bench` always completes and
  prints a report — the numbers just come back marked SKIPPED with a reason
  instead of PASS/FAIL.
  """

  import Ecto.Query

  alias RetrievalNode.Bench.Metrics
  alias RetrievalNode.Embedding
  alias RetrievalNode.Embedding.{NxServingImpl, Serving}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk
  alias RetrievalNode.Search

  @default_queries_path "priv/bench/queries.jsonl"
  @recognized_matcher_keys ~w(repo path_prefix breadcrumb_substring)

  # Synthetic passages for the embed-throughput/RAM probe. The sentence is 13
  # words; 14 repeats lands ~180-200 words (~1.3 tokens/word for a typical
  # BPE tokenizer puts this in the "~200-token" range the protocol asks for).
  @probe_sentence "The retrieval node embeds chunked source code and documentation for hybrid semantic search. "
  @probe_repeats 14
  @probe_passage_count 20

  @type section :: {:ok, map()} | {:skipped, String.t()}

  @type result :: %{
          queries_loaded: non_neg_integer(),
          quality: section,
          embed_probe: section,
          matryoshka: section
        }

  @doc """
  Run the full harness. Options:

    * `:queries_path` — JSONL query file (default `#{@default_queries_path}`)
    * `:top_k` — result count for `Search.hybrid_search/2` and the nDCG@k
      cutoff (default 10, matching the nDCG@10 target)
    * `:skip_embed_probe` — skip the throughput/RAM probe (default `false`)
  """
  @spec run(keyword()) :: result
  def run(opts \\ []) do
    queries_path = Keyword.get(opts, :queries_path, @default_queries_path)
    top_k = Keyword.get(opts, :top_k, 10)
    skip_embed_probe? = Keyword.get(opts, :skip_embed_probe, false)

    queries = load_queries!(queries_path)

    %{
      queries_loaded: length(queries),
      quality: quality_section(queries, top_k),
      embed_probe: embed_probe_section(skip_embed_probe?),
      matryoshka: matryoshka_section(queries, top_k)
    }
  end

  @doc """
  Parse the JSONL query file into a list of query maps (string keys, as
  decoded by `Jason`: `"query"`, `"relevant"`, optional `"note"`).

  Validates every matcher up front: each entry in `"relevant"` must have at
  least one of `#{inspect(@recognized_matcher_keys)}`. An empty/unrecognized
  matcher would build a `WHERE`-less query that matches every chunk in the
  corpus — silently inflating every nDCG score to look artificially good — so
  this raises immediately rather than letting that happen quietly.
  """
  @spec load_queries!(String.t()) :: [map()]
  # sobelow: dev-only benchmark tooling; `path` is a fixed/CLI-supplied fixture
  # path (default priv/bench/queries.jsonl), never untrusted request input.
  # sobelow_skip ["Traversal.FileModule"]
  def load_queries!(path) do
    queries =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    Enum.each(queries, &validate_query!/1)
    queries
  end

  defp validate_query!(%{"query" => q, "relevant" => matchers})
       when is_binary(q) and is_list(matchers) do
    Enum.each(matchers, &validate_matcher!(q, &1))
    :ok
  end

  defp validate_query!(other) do
    raise ArgumentError,
          "bench query missing required \"query\"/\"relevant\" keys: #{inspect(other)}"
  end

  defp validate_matcher!(query, matcher) when is_map(matcher) do
    if Enum.any?(@recognized_matcher_keys, &Map.has_key?(matcher, &1)) do
      :ok
    else
      raise ArgumentError,
            "query #{inspect(query)} has a matcher with none of " <>
              "#{inspect(@recognized_matcher_keys)} — refusing to run it, since an " <>
              "unfiltered matcher would match every chunk in the corpus: #{inspect(matcher)}"
    end
  end

  @doc """
  Resolve a list of relevance matchers (OR'd together) to the set of chunk ids
  currently in the corpus that any of them identify. Each individual matcher
  ANDs together whichever of `repo` / `path_prefix` / `breadcrumb_substring`
  it sets. Matching on these fields (not chunk ids) is what lets the same
  query set survive a re-ingest that assigns fresh ids.
  """
  @spec resolve_relevant_ids([map()]) :: MapSet.t()
  def resolve_relevant_ids(matchers) when is_list(matchers) do
    matchers
    |> Enum.flat_map(&Repo.all(matcher_query(&1)))
    |> MapSet.new()
  end

  defp matcher_query(matcher) do
    Chunk
    |> select([c], c.id)
    |> filter_repo(matcher["repo"])
    |> filter_path_prefix(matcher["path_prefix"])
    |> filter_breadcrumb(matcher["breadcrumb_substring"])
  end

  defp filter_repo(query, nil), do: query
  defp filter_repo(query, repo), do: where(query, [c], c.repo == ^repo)

  defp filter_path_prefix(query, nil), do: query

  defp filter_path_prefix(query, prefix) do
    pattern = like_pattern(prefix) <> "%"
    where(query, [c], fragment("?->>'path' LIKE ? ESCAPE '\\'", c.metadata, ^pattern))
  end

  defp filter_breadcrumb(query, nil), do: query

  defp filter_breadcrumb(query, substring) do
    pattern = "%" <> like_pattern(substring) <> "%"
    where(query, [c], ilike(c.context_breadcrumb, ^pattern))
  end

  # Escape LIKE metacharacters in user-supplied matcher text so a literal `%`
  # or `_` in a path/breadcrumb doesn't act as a wildcard.
  defp like_pattern(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")

  @doc "Whether the `chunks` table has any rows — the corpus-seeded precondition."
  @spec corpus_seeded? :: boolean()
  def corpus_seeded?, do: Repo.exists?(Chunk)

  @doc """
  Whether the configured embedding implementation is ready to embed. The real
  `NxServingImpl` needs `Serving.ready?/0` (post-warmup); any other configured
  impl (e.g. the test-env `StubImpl`) has no warmup concept and is always
  considered ready.
  """
  @spec embedding_ready? :: boolean()
  def embedding_ready? do
    case Embedding.impl() do
      NxServingImpl -> Serving.ready?()
      _other -> true
    end
  end

  # -- Quality: nDCG@k + latency percentiles over Search.hybrid_search/2 -----

  defp quality_section(queries, top_k) do
    cond do
      not corpus_seeded?() ->
        {:skipped, "corpus not seeded — ingest at least one source before running mix rn.bench"}

      not embedding_ready?() ->
        {:skipped, "requires warmed embedding serving; run inside dev with serving enabled"}

      true ->
        {:ok, run_quality(queries, top_k)}
    end
  end

  defp run_quality(queries, top_k) do
    per_query = Enum.map(queries, &score_query(&1, top_k))
    scored = Enum.filter(per_query, & &1.resolvable)
    latencies = Enum.map(scored, & &1.latency_ms)

    %{
      queries_total: length(per_query),
      queries_resolved: length(scored),
      queries_unresolved: length(per_query) - length(scored),
      mean_ndcg_at_k: mean(Enum.map(scored, & &1.ndcg)),
      latency_ms_percentiles: Metrics.percentiles(latencies, [50, 95, 99]),
      per_query: per_query
    }
  end

  defp score_query(%{"query" => text} = q, top_k) do
    relevant_ids = resolve_relevant_ids(q["relevant"])

    if MapSet.size(relevant_ids) == 0 do
      %{query: text, note: q["note"], resolvable: false, ndcg: nil, latency_ms: nil}
    else
      {elapsed_us, hits} = :timer.tc(fn -> Search.hybrid_search(text, top_k: top_k) end)
      ranked_ids = Enum.map(hits, & &1.chunk.id)
      ndcg = Metrics.ndcg_at_k(ranked_ids, relevant_ids, top_k)

      %{
        query: text,
        note: q["note"],
        resolvable: true,
        ndcg: ndcg,
        latency_ms: elapsed_us / 1000
      }
    end
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  # -- Embed throughput + RAM probe ------------------------------------------

  defp embed_probe_section(true), do: {:skipped, "--skip-embed-probe passed"}

  defp embed_probe_section(false) do
    if embedding_ready?() do
      {:ok, run_embed_probe()}
    else
      {:skipped, "requires warmed embedding serving; run inside dev with serving enabled"}
    end
  end

  defp run_embed_probe do
    passages = for i <- 1..@probe_passage_count, do: synthetic_passage(i)

    erlang_before = :erlang.memory(:total)
    os_hwm_before = os_vm_hwm_kb()
    {elapsed_us, vectors} = :timer.tc(fn -> Embedding.embed_batch(passages) end)
    erlang_after = :erlang.memory(:total)
    os_hwm_after = os_vm_hwm_kb()

    elapsed_s = elapsed_us / 1_000_000

    %{
      passages: length(vectors),
      elapsed_s: elapsed_s,
      throughput_passages_per_sec: length(vectors) / elapsed_s,
      ram: %{
        erlang_total_before_mb: bytes_to_mb(erlang_before),
        erlang_total_after_mb: bytes_to_mb(erlang_after),
        erlang_total_delta_mb: bytes_to_mb(erlang_after - erlang_before),
        # VmHWM is a monotonic high-water mark for the OS process, not a
        # snapshot — "after" is the peak RSS observed up to and including the
        # probe; "before" is provided so a caller can see whether the probe
        # itself pushed the peak higher or whether it was already there
        # (e.g. from model load at boot).
        os_vm_hwm_before_mb: kb_to_mb(os_hwm_before),
        os_vm_hwm_after_mb: kb_to_mb(os_hwm_after)
      }
    }
  end

  defp synthetic_passage(i),
    do: String.duplicate(@probe_sentence, @probe_repeats) <> "passage-#{i}"

  defp bytes_to_mb(nil), do: nil
  defp bytes_to_mb(bytes), do: bytes / (1024 * 1024)

  defp kb_to_mb(nil), do: nil
  defp kb_to_mb(kb), do: kb / 1024

  # /proc/self/status is Linux-specific (the arm64 deploy target and this
  # devcontainer both are); returns nil on any other platform or read failure
  # rather than raising, so the probe still completes with the erlang-memory
  # figures alone.
  defp os_vm_hwm_kb do
    with {:ok, content} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/VmHWM:\s+(\d+)\s+kB/, content) do
      String.to_integer(kb)
    else
      _ -> nil
    end
  end

  # -- Matryoshka truncation stability ----------------------------------------
  #
  # The DB's `chunks.embedding` column is `vector(384)` — the corpus was never
  # embedded at 768 dims, and re-embedding it is out of scope here (per the
  # plan: "numbers tuned later"). A true nDCG@10(768) computed against 768-dim
  # corpus vectors is therefore not something this harness can produce; doing
  # so would require either a schema change or on-the-fly re-embedding of every
  # candidate chunk's content, neither of which belongs in a benchmark task.
  #
  # What *is* honestly computable without touching the corpus: for each query,
  # embed at 384 via the normal path (`Embedding.embed/1`, which truncates the
  # model's 768-dim output) and separately fetch the untruncated 768-dim output
  # (`NxServingImpl.embed_full_dims/1`), then apply the same Matryoshka
  # truncation function to it by hand. The two 384-dim vectors *should* be
  # numerically identical (same deterministic truncation math over the same
  # underlying hidden state) — this measures whether they actually are, i.e.
  # whether batching/serving nondeterminism perturbs the truncation path enough
  # to move the ranking. That is reported as a stability delta/overlap, NOT as
  # the 384-vs-768 quality delta from the protocol — the status is always
  # `:skipped` (never PASS/FAIL against the <2% target) with that distinction
  # spelled out, so a report reader can't mistake one for the other.
  defp matryoshka_section(queries, top_k) do
    cond do
      not corpus_seeded?() ->
        {:skipped, "corpus not seeded — ingest at least one source before running mix rn.bench"}

      not embedding_ready?() ->
        {:skipped, "requires warmed embedding serving; run inside dev with serving enabled"}

      Embedding.impl() != NxServingImpl ->
        {:skipped,
         "requires RetrievalNode.Embedding.NxServingImpl (configured impl is " <>
           "#{inspect(Embedding.impl())}); it's the only impl with a Matryoshka " <>
           "truncation step to probe"}

      true ->
        {:ok, run_matryoshka(queries, top_k)}
    end
  end

  defp run_matryoshka(queries, top_k) do
    per_query =
      queries
      |> Enum.map(&matryoshka_query(&1, top_k))
      |> Enum.reject(&is_nil/1)

    %{
      note:
        "PROXY METRIC, not a true 384-vs-768 corpus quality comparison — see " <>
          "RetrievalNode.Bench.Runner moduledoc/comments. chunks.embedding is " <>
          "vector(384) only, so this measures Matryoshka truncation " <>
          "reproducibility (direct 384 embed vs. manual truncation of the " <>
          "untruncated 768-dim output), not retrieval-quality loss from " <>
          "truncating to 384.",
      queries_scored: length(per_query),
      mean_stability_delta: mean(Enum.map(per_query, & &1.stability_delta)),
      mean_overlap_at_k: mean(Enum.map(per_query, & &1.overlap_at_k)),
      per_query: per_query
    }
  end

  defp matryoshka_query(%{"query" => text} = q, top_k) do
    relevant_ids = resolve_relevant_ids(q["relevant"])

    if MapSet.size(relevant_ids) == 0 do
      nil
    else
      q384 = Embedding.embed(text)
      q768 = NxServingImpl.embed_full_dims(text)
      q384_reconstructed = q768 |> Nx.tensor() |> NxServingImpl.matryoshka()

      ranking_a = ranked_ids(text, q384, top_k)
      ranking_b = ranked_ids(text, q384_reconstructed, top_k)

      ndcg_a = Metrics.ndcg_at_k(ranking_a, relevant_ids, top_k)
      ndcg_b = Metrics.ndcg_at_k(ranking_b, relevant_ids, top_k)

      %{
        query: text,
        ndcg_direct_384: ndcg_a,
        ndcg_reconstructed_from_768: ndcg_b,
        stability_delta: ndcg_a - ndcg_b,
        overlap_at_k: overlap_at_k(ranking_a, ranking_b)
      }
    end
  end

  defp ranked_ids(text, embedding, top_k) do
    text
    |> Search.hybrid_search(embedding: embedding, top_k: top_k)
    |> Enum.map(& &1.chunk.id)
  end

  defp overlap_at_k([], []), do: 1.0

  defp overlap_at_k(a, b) do
    k = max(length(a), length(b))
    common = MapSet.intersection(MapSet.new(a), MapSet.new(b)) |> MapSet.size()
    common / k
  end
end
