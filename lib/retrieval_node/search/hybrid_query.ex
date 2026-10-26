defmodule RetrievalNode.Search.HybridQuery do
  @moduledoc """
  Reciprocal Rank Fusion (k=60) over pgvector cosine similarity and Postgres
  full-text search.

  Implemented as raw SQL via `Repo.query/2` rather than the `Ecto.Query`
  `with_cte`/full-join DSL: a two-CTE RRF fusion with window functions is right
  at the edge of what the macro DSL expresses cleanly, and the load-bearing
  correctness property is far easier to read (and `EXPLAIN ANALYZE`) in plain
  SQL. That property: the optional `source_id`/`repo`/`lang`/`source_type`
  filters are applied **inside each leg's own `WHERE`** — so the `row_number()`
  window ranks only the already-filtered set. A filter applied after fusion
  could let an out-of-scope chunk consume a rank-1 slot and starve an in-scope
  chunk, silently degrading filtered recall.

  The legs query `chunks` directly and do **not** share a `candidates` CTE. An
  earlier version filtered via `SELECT id FROM chunks WHERE (filters)` in a
  CTE joined into both legs; Postgres materializes a CTE referenced more than
  once, which forces a hash/nested-loop join against that materialized set —
  and that join, not the filters themselves, is what defeated both
  `chunks_embedding_hnsw_idx` and `chunks_tsv_gin_idx` (confirmed live:
  `pg_stat_user_indexes` showed the HNSW index at `idx_scan = 0`). Inlining the
  same filter predicates directly into each leg's `WHERE` lets the planner push
  them below the `ORDER BY ... LIMIT`, so `vector_search` drives off the HNSW
  index (pgvector 0.8.5 supports iterative index scans, so a `WHERE` predicate
  alongside `ORDER BY embedding <=> $1` does not force it back to an exact
  scan) and `fts_search` drives off the GIN index, instead of both falling
  back to a sequential scan + sort over the whole table.

  A third, optional leg — `entity_search` — joins the code-graph tables
  (`entities`/`entity_mentions`) to surface chunks reachable only through a
  symbol match: `significant_terms/1` of the query are matched against
  `entities.qualified_name` as case-insensitive substrings (`ILIKE`, served by
  the GIN trigram index), then followed through `entity_mentions` to the defining,
  calling or importing chunk. It obeys the same filter-inlining law as the
  other legs and contributes to `fused` at `:graph_leg_weight` rather than
  1.0, since it is unproven relative to the tuned vector/FTS pair. The leg is
  **off by default** and only planned into the query when requested AND the
  query yields at least one significant term; otherwise the SQL is the plain
  two-leg query, built from the same shared fragments, so the entity JOIN
  cost is never paid unless the leg runs. Cost scales with how many entities
  each term matches, so the leg is bounded three ways: a term matching more
  than `@term_match_cap` entities is dropped as non-discriminating, the
  matched pool is capped, and the whole graph query runs under a
  `:graph_leg_timeout_ms` statement timeout, falling back to the plain
  two-leg query (with a warning) if it is exceeded.

  ## Vector leg depth

  pgvector's HNSW scan returns at most `hnsw.ef_search` rows (default 40),
  whatever the `LIMIT`, and applies a `WHERE` filter to those candidates
  afterwards. Left at defaults, the vector leg's "`@candidate_pool`
  candidates" would be ~40 (fewer when filtered), starving fusion of
  exact-rank answers. So every execution of a query containing the vector leg
  runs under `with_vector_scan_settings/1`: `hnsw.ef_search` = the candidate
  pool (the pool must not exceed pgvector's 1000 cap) and
  `hnsw.iterative_scan = strict_order`, which keeps scanning until `LIMIT`
  filtered rows are found while preserving exact distance order
  (`relaxed_order` was measured to reorder results). The settings are
  transaction-local.

  Returns back-link projection maps (no `content`) ordered by fused score desc;
  full content is fetched separately (`get_file` / targeted `Repo.get`) only when
  a result is actually expanded, keeping the hot search path row/token-lean.
  """

  require Logger

  alias RetrievalNode.Repo

  @rrf_k 60
  @default_top_k 20
  # Upper bound on top_k so an MCP caller can't request an unbounded LIMIT.
  @max_top_k 100
  # Per-side candidate pool feeding fusion. Configurable so tests can shrink it
  # to exercise pool-starvation (the filters-inside-CTE property) without seeding
  # 200+ rows. Defaults to 200 in prod.
  @candidate_pool Application.compile_env(:retrieval_node, :rrf_candidate_pool, 200)

  if @candidate_pool < 1 or @candidate_pool > 1000 do
    raise CompileError,
      description: ":rrf_candidate_pool must be within 1..1000 (pgvector hnsw.ef_search cap)"
  end

  @vector_scan_gucs [
    {"hnsw.ef_search", Integer.to_string(@candidate_pool)},
    {"hnsw.iterative_scan", "strict_order"}
  ]

  @vector_scan_settings_sql "SELECT set_config('hnsw.ef_search', $1, true), set_config('hnsw.iterative_scan', $2, true)"

  # significant_terms/1 tuning: terms under this length are noise (stopword-ish
  # fragments), and each extra term is one more `unnest` row evaluated per
  # candidate row in the entity leg's scalar subquery, so the cap keeps that
  # leg's cost bounded even for a long natural-language query.
  @min_term_length 3
  @max_terms 8
  # No real code symbol exceeds this length; an oversized token (e.g. a
  # pasted blob) would make word_similarity O(term x name) per candidate row.
  @max_term_length 64

  # English function words that survive the length filter but carry no symbol
  # signal and actively hurt: "the" matches a huge share of entities, so it
  # costs a scan for nothing. Deliberately conservative: words that double as common code symbols
  # (get, set, run, new, all, ...) are NOT listed.
  @stopwords MapSet.new(~w(the and for from with this that these those how does doing done
                  what where when which who whom why are was were been being have
                  has had can could should would will shall may might must not
                  nor but into onto over under about after before between during
                  without within than then them they their there you your yours
                  our ours its his her hers him she very just also each some
                  such only same more most other both few))

  # Mention-kind weights for the entity leg's score, as SQL CASE literals
  # below: a `definition` mention means the chunk IS the symbol (strongest
  # signal), a `call` mention merely references it (weaker), and an `import`
  # mention only brings the name into scope (weakest).
  @mention_weight_definition 1.0
  @mention_weight_call 0.6
  @mention_weight_import 0.3

  @type result :: %{
          chunk_id: Ecto.UUID.t(),
          source_type: String.t(),
          repo: String.t() | nil,
          lang: String.t() | nil,
          context_breadcrumb: String.t(),
          metadata: map(),
          fused_score: float()
        }

  @type opts :: [
          embedding: [float()],
          text_query: String.t(),
          source_id: Ecto.UUID.t() | nil,
          source_type: String.t() | nil,
          repo: String.t() | nil,
          lang: String.t() | nil,
          top_k: pos_integer(),
          graph: boolean()
        ]

  # ---------------------------------------------------------------------
  # Shared SQL fragments. Both the two-leg (graph off) and three-leg (graph
  # on) queries are assembled from these so the vector/FTS legs are never
  # duplicated in source, and the two-leg query is exactly the original
  # query — no entity JOIN text appears in it at all.
  # ---------------------------------------------------------------------

  # Filter predicates against a bare `chunks` FROM (vector_search, fts_search).
  @filters_bare """
  AND ($5::uuid IS NULL OR source_id = $5)
      AND ($6::text IS NULL OR repo = $6)
      AND ($7::text IS NULL OR lang = $7)
      AND ($8::text IS NULL OR source_type = $8)\
  """

  # Same four filters, qualified for the entity leg's joined `chunks c`.
  @filters_c """
  AND ($5::uuid IS NULL OR c.source_id = $5)
      AND ($6::text IS NULL OR c.repo = $6)
      AND ($7::text IS NULL OR c.lang = $7)
      AND ($8::text IS NULL OR c.source_type = $8)\
  """

  @vector_leg_sql """
  vector_search AS (
    SELECT id, row_number() OVER (ORDER BY embedding <=> $1::vector) AS rank
    FROM chunks
    WHERE embedding IS NOT NULL
      #{@filters_bare}
    ORDER BY embedding <=> $1::vector
    LIMIT #{@candidate_pool}
  )\
  """

  @fts_leg_sql """
  fts_search AS (
    SELECT id, row_number() OVER (
      ORDER BY ts_rank(tsv, websearch_to_tsquery('english', $2)) DESC
    ) AS rank
    FROM chunks
    WHERE tsv @@ websearch_to_tsquery('english', $2)
      #{@filters_bare}
    ORDER BY ts_rank(tsv, websearch_to_tsquery('english', $2)) DESC
    LIMIT #{@candidate_pool}
  )\
  """

  # Cap on the entity pre-selection pool (entity_matches below): bounds the
  # mention-join fan-out to 500 entities.
  @entity_match_pool 500

  # A term matching more than this many entities is dropped from the entity
  # leg: it names nothing in particular (`get`, `config`), and scanning its
  # matches is what made the leg cost hundreds of ms.
  @term_match_cap 200

  # entity_search: each significant query term ($10+) is matched as an ILIKE
  # substring of entities.qualified_name (trigram GIN index), then followed
  # through entity_mentions to the linked chunk. Two stages, and the split
  # matters: `entity_matches` pre-selects matching symbols FIRST, scores only
  # those rows by word_similarity, and caps the pool at #{@entity_match_pool}
  # (see entity_matches_sql/1 for the per-term shape and cap). Folding the name
  # match into the three-way join lets the planner drive from chunks->mentions
  # instead. MATERIALIZED is deliberate and does not violate the moduledoc's
  # shared-CTE law: that law is about a filter CTE shared by MULTIPLE legs
  # defeating their indexes, whereas entity_matches is referenced once,
  # bounded, and materializing it stops the planner from inlining it back into
  # the join.
  #
  # Tradeoff: entities carry no repo column, so only `source_id` and `lang`
  # (an entity's language is the lang of the chunks that mention it) narrow the
  # pre-selection; repo applies afterwards at the chunks join, so a
  # repo-filtered query whose symbols rank below the pool can starve this leg.
  # Acceptable because the leg is additive.
  #
  # entity_search applies mention-kind weights, then GROUP BY c.id keeps each
  # chunk's best (MAX) score *before* row_number ranks the deduped set — one
  # rank per chunk id, like the other legs.
  @entity_leg_sql """
  entity_search AS (
    SELECT id, row_number() OVER (ORDER BY score DESC) AS rank
    FROM (
      SELECT
        c.id AS id,
        MAX(
          m.sim
          * CASE em.kind
              WHEN 'definition' THEN #{@mention_weight_definition}
              WHEN 'call' THEN #{@mention_weight_call}
              WHEN 'import' THEN #{@mention_weight_import}
            END
        ) AS score
      FROM entity_matches m
      JOIN entity_mentions em ON em.entity_id = m.id
      JOIN chunks c ON c.id = em.chunk_id
      WHERE TRUE
        #{@filters_c}
      GROUP BY c.id
    ) entity_chunk_scores
    ORDER BY score DESC
    LIMIT #{@candidate_pool}
  )\
  """

  @fused_two_leg_sql """
  fused AS (
    SELECT id, SUM(1.0 / ($3 + rank)) AS score
    FROM (
      SELECT id, rank FROM vector_search
      UNION ALL
      SELECT id, rank FROM fts_search
    ) ranked
    GROUP BY id
  )\
  """

  # entity_search contributes at weight $10 (config `:graph_leg_weight`)
  # rather than 1.0 like the tuned vector/FTS pair — see moduledoc.
  @fused_three_leg_sql """
  fused AS (
    SELECT id, SUM(weight / ($3 + rank)) AS score
    FROM (
      SELECT id, rank, 1.0::float AS weight FROM vector_search
      UNION ALL
      SELECT id, rank, 1.0::float AS weight FROM fts_search
      UNION ALL
      SELECT id, rank, $9::float AS weight FROM entity_search
    ) ranked
    GROUP BY id
  )\
  """

  @select_sql """
  SELECT
    c.id, c.source_type, c.repo, c.lang, c.context_breadcrumb, c.metadata,
    fused.score AS fused_score
  FROM fused
  JOIN chunks c ON c.id = fused.id
  ORDER BY fused.score DESC
  LIMIT $4\
  """

  @sql """
  WITH #{@vector_leg_sql},
  #{@fts_leg_sql},
  #{@fused_two_leg_sql}
  #{@select_sql}
  """

  # One sub-select per significant term, text-built per call (the term count
  # varies, 1..8): each term's pattern is a bind parameter at its own position,
  # so the planner sees a CONSTANT pattern and picks the trigram GIN index. A
  # single `unnest(...) CROSS JOIN LATERAL` form hides the pattern from the
  # planner, which then prefers a LIMIT-driven seq scan of the whole entities
  # table. A term matching more than @term_match_cap entities is dropped from
  # the leg (non-discriminating; see the cap's comment). Term i binds at
  # $(10 + 2i) with its ILIKE pattern at $(11 + 2i).
  defp entity_matches_sql(term_count) do
    per_term =
      Enum.map_join(0..(term_count - 1), "\n      UNION ALL\n", fn i ->
        term = 10 + 2 * i
        pat = 11 + 2 * i

        """
        (SELECT #{i} AS term_idx, e.id, word_similarity($#{term}::text, e.qualified_name) AS sim
         FROM entities e
         WHERE e.qualified_name ILIKE $#{pat}::text
           AND ($5::uuid IS NULL OR e.source_id = $5)
           AND ($7::text IS NULL OR e.language = $7)
         LIMIT #{@term_match_cap + 1})\
        """
      end)

    """
    entity_matches AS MATERIALIZED (
      SELECT id, max(sim) AS sim
      FROM (
        SELECT id, sim, count(*) OVER (PARTITION BY term_idx) AS term_matches
        FROM (
          #{per_term}
        ) per_term
      ) matched
      WHERE term_matches <= #{@term_match_cap}
      GROUP BY id
      ORDER BY sim DESC
      LIMIT #{@entity_match_pool}
    )\
    """
  end

  defp graph_sql(term_count) do
    """
    WITH #{@vector_leg_sql},
    #{@fts_leg_sql},
    #{entity_matches_sql(term_count)},
    #{@entity_leg_sql},
    #{@fused_three_leg_sql}
    #{@select_sql}
    """
  end

  @doc """
  Run the RRF hybrid query. Requires `:embedding` (a 384-float query vector) and
  `:text_query` (free-form, parsed with `websearch_to_tsquery`). Optional
  `:source_id`/`:source_type`/`:repo`/`:lang` filters and `:top_k`
  (default #{@default_top_k}). `:source_type` is the DB enum string
  (`"git_repo"`/`"jira_project"`/`"drive_folder"`).

  `:graph` (default from config `:graph_leg_default`, currently `false`) adds
  the third entity-mention leg described in the moduledoc. The leg
  ships opt-in: its query cost is paid on every request it runs on,
  whether or not relevance improves. When true but `text_query` yields no
  `significant_terms/1`, the leg is silently skipped (nothing to match) and
  the plain two-leg query runs instead.
  """
  @spec search(opts) :: [result]
  # sobelow: the SQL is one compile-time attribute (@sql) or graph_sql/1,
  # whose only interpolation is compile-time constants and positional
  # placeholders; every runtime value — including the terms — travels as a
  # bind parameter.
  # sobelow_skip ["SQL.Query"]
  def search(opts) do
    embedding = Keyword.fetch!(opts, :embedding)
    text_query = Keyword.fetch!(opts, :text_query)
    top_k = opts |> Keyword.get(:top_k, @default_top_k) |> clamp_top_k()

    graph_requested? =
      Keyword.get(opts, :graph, Application.get_env(:retrieval_node, :graph_leg_default, false)) ==
        true

    terms = if graph_requested?, do: significant_terms(text_query), else: []
    graph? = graph_requested? and terms != []

    base_params = [
      Pgvector.new(embedding),
      text_query,
      @rrf_k,
      top_k,
      dump_uuid(opts[:source_id]),
      opts[:repo],
      opts[:lang],
      opts[:source_type]
    ]

    plain = fn -> with_vector_scan_settings(fn -> Repo.query!(@sql, base_params) end) end

    result =
      if graph? do
        graph_params =
          base_params ++ [graph_leg_weight() | Enum.flat_map(terms, &[&1, like_pattern(&1)])]

        case run_graph_query(graph_sql(length(terms)), graph_params, graph_leg_timeout_ms()) do
          {:ok, result} ->
            result

          :timeout ->
            Logger.warning(
              "HybridQuery: graph leg exceeded #{graph_leg_timeout_ms()}ms, " <>
                "falling back to vector+FTS for #{inspect(significant_terms(text_query))}"
            )

            plain.()
        end
      else
        plain.()
      end

    %Postgrex.Result{rows: rows} = result
    Enum.map(rows, &row_to_result/1)
  end

  @doc false
  # Runs the graph-leg query under a transaction-scoped statement_timeout so a
  # pathological term set degrades to the plain query instead of stalling the
  # request. The timeout is set and restored inside the transaction, so it
  # can't leak to later statements. Ecto flattens a nested Repo.transaction
  # into the caller's, so the graph query itself runs under its own savepoint
  # (`mode: :savepoint`): a cancel rolls back only that savepoint and never
  # aborts a caller's transaction, so the plain-query fallback can still run.
  # Public only so tests can exercise the timeout path directly.
  # sobelow_skip ["SQL.Query"]
  @spec run_graph_query(String.t(), [term()], pos_integer()) ::
          {:ok, Postgrex.Result.t()} | :timeout
  def run_graph_query(sql, params, timeout_ms) do
    outcome =
      with_vector_scan_settings(fn ->
        %Postgrex.Result{rows: [[previous]]} =
          Repo.query!("SELECT current_setting('statement_timeout')")

        Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{timeout_ms}ms"])
        outcome = Repo.query(sql, params, mode: :savepoint)
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", [previous])
        outcome
      end)

    case outcome do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} -> :timeout
      {:error, error} -> raise error
    end
  end

  @doc false
  # The single choke point for executing SQL that contains the vector leg:
  # applies the pgvector HNSW scan settings (see moduledoc) transaction-locally
  # around `fun`, returning its result. One statement suffices even on a fresh
  # connection: the placeholder GUCs are adopted when pgvector loads. Inside a
  # caller's transaction (a savepoint) the settings outlive the call until that
  # transaction ends; that is harmless, as they only widen the HNSW scan for
  # any later vector query in it. Public only so tests can observe the settings
  # while `fun` runs.
  @spec with_vector_scan_settings((-> result)) :: result when result: term()
  def with_vector_scan_settings(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!(@vector_scan_settings_sql, Enum.map(@vector_scan_gucs, &elem(&1, 1)))
        fun.()
      end)

    result
  end

  defp graph_leg_timeout_ms do
    case Application.get_env(:retrieval_node, :graph_leg_timeout_ms, 50) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 50
    end
  end

  # Substring pattern for the entity leg's ILIKE, built here (not in SQL) so the
  # planner sees a plain `ILIKE column_ref` it can serve from the trigram GIN
  # index; an in-SQL replace()/ESCAPE wrapper forces a seq scan. Backslash is
  # ILIKE's default escape character.
  defp like_pattern(term), do: "%" <> String.replace(term, ~r/([%_\\])/, "\\\\\\1") <> "%"

  # Normalized to a non-negative float: the SQL binds it as `$9::float`, and a
  # misconfigured (negative/non-numeric) weight must not invert or break fusion.
  defp graph_leg_weight do
    case Application.get_env(:retrieval_node, :graph_leg_weight, 0.5) do
      w when is_number(w) and w >= 0 -> w * 1.0
      _ -> 0.5
    end
  end

  @doc """
  Extract significant terms from free-form query text for the entity leg's
  substring match: split on non-alphanumeric/underscore boundaries (keeping `_`
  so snake_case symbols like `process_payment` survive as one term), downcase,
  drop terms shorter than #{@min_term_length} chars or longer than
  #{@max_term_length} chars, dedup preserving first-seen order, and cap at
  #{@max_terms} terms. Returns `[]` when nothing qualifies (e.g. an
  all-short-words or empty query) — the caller then skips the entity leg
  entirely rather than running it with no terms.
  """
  @spec significant_terms(String.t()) :: [String.t()]
  def significant_terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(
      &(String.length(&1) < @min_term_length or String.length(&1) > @max_term_length or
          MapSet.member?(@stopwords, &1))
    )
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  defp row_to_result([id, source_type, repo, lang, breadcrumb, metadata, fused_score]) do
    %{
      chunk_id: Ecto.UUID.cast!(id),
      source_type: source_type,
      repo: repo,
      lang: lang,
      context_breadcrumb: breadcrumb,
      metadata: metadata,
      fused_score: to_float(fused_score)
    }
  end

  # fused_score comes back as Decimal (SUM of numeric division); normalize to float.
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  @doc "The largest `top_k` `search/1` will honor."
  @spec max_top_k() :: pos_integer()
  def max_top_k, do: @max_top_k

  @doc """
  Clamp a caller-supplied `top_k` to `[1, #{@max_top_k}]`, defaulting to
  #{@default_top_k} for anything that isn't a positive integer — the same
  normalization `search/1` applies to its own `:top_k`. Exposed so `Search`'s
  rerank funnel, which picks its candidate pool size before calling
  `search/1`, shares it rather than duplicating the constants.
  """
  @spec clamp_top_k(term()) :: pos_integer()
  def clamp_top_k(k) when is_integer(k) and k >= 1, do: min(k, @max_top_k)
  def clamp_top_k(_), do: @default_top_k

  # Raw `Repo.query!` binds `$5::uuid` as Postgrex's 16-byte binary, not the
  # 36-char string form callers hold.
  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
