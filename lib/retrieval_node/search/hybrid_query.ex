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
  symbol match: it takes the caller's significant query terms
  (`significant_terms/1`) and matches them against `entities.qualified_name`
  via pg_trgm word-similarity (`%>`, GIN-trgm indexable), then follows
  `entity_mentions` to the defining/calling/importing chunk. It obeys the same
  filter-inlining law as the other two legs — its own `WHERE`, its own
  `ORDER BY ... LIMIT` candidate pool, its own `row_number()` — and
  contributes to `fused` at a configurable weight
  (`:graph_leg_weight`) rather than 1.0, since it is unproven relative to the
  tuned vector/FTS pair (see config comment). The leg ships **off by default**
  and is only planned into the query when the caller asks for it AND the
  query text yields at least one significant term — an empty term list can
  never match `%> ANY($9)`, so running the leg would just pay a JOIN for a
  guaranteed no-op. When the leg is skipped, the SQL sent to Postgres is the
  original two-leg query (built from the same shared fragments, not a
  parallel copy) — the entity JOIN cost is never paid unless the leg runs.

  Returns back-link projection maps (no `content`) ordered by fused score desc;
  full content is fetched separately (`get_file` / targeted `Repo.get`) only when
  a result is actually expanded, keeping the hot search path row/token-lean.
  """

  alias RetrievalNode.Repo

  @rrf_k 60
  @default_top_k 20
  # Upper bound on top_k so an MCP caller can't request an unbounded LIMIT.
  @max_top_k 100
  # Per-side candidate pool feeding fusion. Configurable so tests can shrink it
  # to exercise pool-starvation (the filters-inside-CTE property) without seeding
  # 200+ rows. Defaults to 200 in prod.
  @candidate_pool Application.compile_env(:retrieval_node, :rrf_candidate_pool, 200)

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
  # signal — and actively hurt: a term like "the" is a single, ubiquitous
  # trigram, so `%> ANY` with it in the array makes the planner abandon
  # `entities_qualified_name_trgm_idx` for a parallel seq scan (measured
  # 1.29s vs 43ms on the 227k-entity corpus). Deliberately conservative:
  # words that double as common code symbols (get, set, run, new, all, ...)
  # are NOT listed — dropping grammar words is a latency fix, not relevance
  # tuning, and exact-symbol lookup belongs to `related_code` anyway.
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

  # Cap on the entity pre-selection pool (entity_matches below). 500 symbols
  # comfortably covers every plausible "query mentions these names" set while
  # bounding the mention-join fan-out to ~500 index-only lookups.
  @entity_match_pool 500

  # entity_search: trigram word-similarity of the caller's significant query
  # terms ($9) against entities.qualified_name, followed through
  # entity_mentions to the linked chunk. Two stages, and the split is
  # load-bearing (EXPLAIN-verified on the 595k-chunk/227k-entity corpus):
  #
  # `entity_matches` pre-selects matching symbols FIRST, driving off
  # `entities_qualified_name_trgm_idx` (`%>` is pg_trgm's commutator form of
  # `word_similarity(term, indexed_col) >= threshold` with the INDEXED column
  # on the left), computes word-similarity only for those rows, and caps the
  # pool. Folding the trigram match into the three-way join instead let the
  # planner drive from chunks→mentions and evaluate `%>` + the similarity
  # subquery per mention row: 450-570ms; this shape runs ~43ms. MATERIALIZED
  # is deliberate and does NOT violate the moduledoc's shared-CTE law — that
  # law is about a filter CTE referenced by MULTIPLE legs defeating their
  # indexes; entity_matches is referenced exactly once, is bounded to
  # #{@entity_match_pool} rows, and materializing it is precisely what stops
  # the planner from inlining it back into the join.
  #
  # Known tradeoff (review W4): entities carry no repo/lang columns, so the
  # pre-selection is corpus-wide; a repo/lang filter applies afterwards at the
  # chunks join. A heavily-filtered query whose symbols rank below the top
  # #{@entity_match_pool} corpus-wide matches can starve this leg — acceptable
  # because the leg is additive (vector/FTS legs still cover the query) and
  # the alternative (per-leg filter pushdown into entities) would require
  # denormalizing repo/lang onto every entity row.
  #
  # entity_search then applies mention-kind weights and, as a chunk can be
  # reached by several mentions (multiple terms, multiple entities, or several
  # mentions of the same entity), GROUP BY c.id collapses those to one row
  # keeping the best (MAX) score *before* row_number ranks the deduped set,
  # matching the "one rank per chunk id" shape of the other two legs.
  @entity_matches_sql """
  entity_matches AS MATERIALIZED (
    SELECT
      e.id,
      (SELECT max(word_similarity(t, e.qualified_name)) FROM unnest($9::text[]) t) AS sim
    FROM entities e
    WHERE e.qualified_name %> ANY($9::text[])
    ORDER BY sim DESC
    LIMIT #{@entity_match_pool}
  )\
  """

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
      SELECT id, rank, $10::float AS weight FROM entity_search
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

  @sql_graph """
  WITH #{@vector_leg_sql},
  #{@fts_leg_sql},
  #{@entity_matches_sql},
  #{@entity_leg_sql},
  #{@fused_three_leg_sql}
  #{@select_sql}
  """

  @doc """
  Run the RRF hybrid query. Requires `:embedding` (a 384-float query vector) and
  `:text_query` (free-form, parsed with `websearch_to_tsquery`). Optional
  `:source_id`/`:source_type`/`:repo`/`:lang` filters and `:top_k`
  (default #{@default_top_k}). `:source_type` is the DB enum string
  (`"git_repo"`/`"jira_project"`/`"drive_folder"`).

  `:graph` (default from config `:graph_leg_default`, currently `false` until
  the Phase-3.3 EXPLAIN + latency validation on the real corpus passes) adds
  the third entity-mention leg described in the moduledoc. When true but
  `text_query` yields no `significant_terms/1`, the leg is silently skipped
  (nothing to match) and the plain two-leg query runs instead.
  """
  @spec search(opts) :: [result]
  # sobelow: `sql` is one of two compile-time module attributes (@sql /
  # @sql_graph) whose only interpolation is compile-time constants; every
  # runtime value — including the term list — travels as a bind parameter.
  # sobelow_skip ["SQL.Query"]
  def search(opts) do
    embedding = Keyword.fetch!(opts, :embedding)
    text_query = Keyword.fetch!(opts, :text_query)
    top_k = opts |> Keyword.get(:top_k, @default_top_k) |> clamp_top_k()

    graph_requested? =
      Keyword.get(opts, :graph, Application.get_env(:retrieval_node, :graph_leg_default, false))

    terms = if graph_requested?, do: significant_terms(text_query), else: []
    graph? = graph_requested? and terms != []

    base_params = [
      Pgvector.new(embedding),
      text_query,
      @rrf_k,
      top_k,
      opts[:source_id],
      opts[:repo],
      opts[:lang],
      opts[:source_type]
    ]

    {sql, params} =
      if graph? do
        graph_weight = Application.get_env(:retrieval_node, :graph_leg_weight, 0.5)
        {@sql_graph, base_params ++ [terms, graph_weight]}
      else
        {@sql, base_params}
      end

    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, &row_to_result/1)
  end

  @doc """
  Extract significant terms from free-form query text for the entity leg's
  trigram match: split on non-alphanumeric/underscore boundaries (keeping `_`
  so snake_case symbols like `process_payment` survive as one term), downcase,
  drop terms shorter than #{@min_term_length} chars or longer than
  #{@max_term_length} chars, dedup preserving first-seen order, and cap at
  #{@max_terms} terms. Returns `[]` when nothing qualifies (e.g. an
  all-short-words or empty query) — the caller then skips the entity leg
  entirely rather than running it with a match-nothing `$9`.
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

  # Clamp to [1, @max_top_k] so a caller (eventually the MCP tool layer) can't
  # request an unbounded or nonsensical LIMIT.
  defp clamp_top_k(k) when is_integer(k) and k >= 1, do: min(k, @max_top_k)
  defp clamp_top_k(_), do: @default_top_k
end
