defmodule RetrievalNode.Search.HybridQuery do
  @moduledoc """
  Reciprocal Rank Fusion (k=60) over pgvector cosine similarity and Postgres
  full-text search.

  Implemented as raw SQL via `Repo.query/2` rather than the `Ecto.Query`
  `with_cte`/full-join DSL: a two-CTE RRF fusion with window functions is right
  at the edge of what the macro DSL expresses cleanly, and the load-bearing
  correctness property is far easier to read (and `EXPLAIN ANALYZE`) in plain
  SQL. That property: the optional `source_id`/`repo`/`lang` filters are applied
  **inside** a shared `candidates` CTE that feeds *both* the vector and FTS
  ranking CTEs — so the `row_number()` window ranks only the already-filtered
  set. A filter applied after fusion could let an out-of-scope chunk consume a
  rank-1 slot and starve an in-scope chunk, silently degrading filtered recall.

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
          top_k: pos_integer()
        ]

  @sql """
  WITH candidates AS (
    SELECT id FROM chunks
    WHERE ($5::uuid IS NULL OR source_id = $5)
      AND ($6::text IS NULL OR repo = $6)
      AND ($7::text IS NULL OR lang = $7)
      AND ($8::text IS NULL OR source_type = $8)
  ),
  vector_search AS (
    SELECT c.id, row_number() OVER (ORDER BY c.embedding <=> $1::vector) AS rank
    FROM chunks c JOIN candidates ON candidates.id = c.id
    WHERE c.embedding IS NOT NULL
    ORDER BY c.embedding <=> $1::vector
    LIMIT #{@candidate_pool}
  ),
  fts_search AS (
    SELECT c.id, row_number() OVER (
      ORDER BY ts_rank(c.tsv, websearch_to_tsquery('english', $2)) DESC
    ) AS rank
    FROM chunks c JOIN candidates ON candidates.id = c.id
    WHERE c.tsv @@ websearch_to_tsquery('english', $2)
    ORDER BY ts_rank(c.tsv, websearch_to_tsquery('english', $2)) DESC
    LIMIT #{@candidate_pool}
  ),
  fused AS (
    SELECT id, SUM(1.0 / ($3 + rank)) AS score
    FROM (
      SELECT id, rank FROM vector_search
      UNION ALL
      SELECT id, rank FROM fts_search
    ) ranked
    GROUP BY id
  )
  SELECT
    c.id, c.source_type, c.repo, c.lang, c.context_breadcrumb, c.metadata,
    fused.score AS fused_score
  FROM fused
  JOIN chunks c ON c.id = fused.id
  ORDER BY fused.score DESC
  LIMIT $4
  """

  @doc """
  Run the RRF hybrid query. Requires `:embedding` (a 384-float query vector) and
  `:text_query` (free-form, parsed with `websearch_to_tsquery`). Optional
  `:source_id`/`:source_type`/`:repo`/`:lang` filters and `:top_k`
  (default #{@default_top_k}). `:source_type` is the DB enum string
  (`"git_repo"`/`"jira_project"`/`"drive_folder"`).
  """
  @spec search(opts) :: [result]
  def search(opts) do
    embedding = Keyword.fetch!(opts, :embedding)
    text_query = Keyword.fetch!(opts, :text_query)
    top_k = opts |> Keyword.get(:top_k, @default_top_k) |> clamp_top_k()

    params = [
      Pgvector.new(embedding),
      text_query,
      @rrf_k,
      top_k,
      opts[:source_id],
      opts[:repo],
      opts[:lang],
      opts[:source_type]
    ]

    %Postgrex.Result{rows: rows} = Repo.query!(@sql, params)
    Enum.map(rows, &row_to_result/1)
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
