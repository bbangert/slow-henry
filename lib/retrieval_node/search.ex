defmodule RetrievalNode.Search do
  @moduledoc """
  Search context — the public entry point for hybrid retrieval.

  One of the two contexts (with `Ingest`) allowed to touch `Repo`. Embeds the
  query text via the configured `Embedding` impl, runs the RRF `HybridQuery`, and
  assembles back-link results (`%{chunk, score}`) — deliberately *not* full
  content, which callers fetch separately when a hit is expanded.
  """

  import Ecto.Query

  alias RetrievalNode.Embedding
  alias RetrievalNode.Repo
  alias RetrievalNode.Reranking
  alias RetrievalNode.Retrieval.Chunk
  alias RetrievalNode.Search.HybridQuery

  @default_top_k 20

  @type hit ::
          %{chunk: map(), score: float()} | %{chunk: map(), score: float(), fused_score: float()}

  @doc """
  Hybrid (dense + BM25/RRF) search over the query text.

  Options:
    * `:source_id` / `:source_type` / `:repo` / `:lang` — optional filters applied
      inside both ranking CTEs (see `HybridQuery`). `:source_type` is the DB enum
      string (`"git_repo"`/`"jira_project"`/`"drive_folder"`)
    * `:top_k` — result count (default 20)
    * `:graph` — boolean; adds `HybridQuery`'s third entity-mention leg (default
      from config `:graph_leg_default`, currently `false`). The Phase-3.3
      EXPLAIN + latency validation has passed (~71ms end-to-end added on the
      full corpus); it stays opt-in because that cost is paid on every request
      whether or not the leg improves relevance, and proving the latter needs
      a relevance eval (same bar as the rerank Phase-1.4 gate below). Exposed
      on the MCP tool layer as the `graph` field on `semantic_search`.
    * `:embedding` — a precomputed 384-float query vector; when given, skips the
      embedding step (used by tests and callers that already hold an embedding)
    * `:rerank` — boolean; defaults from config `:rerank_default` (currently
      `false`, until the Phase-1.4 eval gate — MRR/Hit@k + p95 ≤ 300ms on the
      real corpus — proves the cross-encoder wins). When true, runs the funnel:
      fetch a candidate pool of `max(rerank_candidates(), top_k)` (config
      `:rerank_candidates`, default 50) via RRF, load their `content`, score
      each with `Reranking.rerank_scores/2`, and return only the top `:top_k`
      by *rerank* score. Rerank scores are raw cross-encoder logits, not RRF
      scores — a caller comparing scores across rerank on/off must use
      `:fused_score` (present only in rerank hits), not `:score`.

  Returns hits ordered by score descending (fused score normally; rerank score
  when `:rerank` is active). Each `:chunk` is a back-link projection (`id`,
  `source_type`, `repo`, `lang`, `context_breadcrumb`, `metadata`) — never
  `content`. Rerank hits additionally carry `:fused_score`, the original RRF
  score, preserved alongside for eval comparison; non-rerank hits keep the
  plain `%{chunk:, score:}` shape unchanged.
  """
  @spec hybrid_search(String.t(), keyword()) :: [hit]
  def hybrid_search(query_text, opts \\ []) when is_binary(query_text) do
    embedding = Keyword.get_lazy(opts, :embedding, fn -> Embedding.embed(query_text) end)
    top_k = opts |> Keyword.get(:top_k, @default_top_k) |> HybridQuery.clamp_top_k()

    rerank? =
      Keyword.get(opts, :rerank, Application.get_env(:retrieval_node, :rerank_default, false))

    query_top_k = if rerank?, do: max(rerank_candidates(), top_k), else: top_k

    query_opts =
      opts
      |> Keyword.take([:source_id, :source_type, :repo, :lang, :graph])
      |> Keyword.merge(embedding: embedding, text_query: query_text, top_k: query_top_k)

    rows = HybridQuery.search(query_opts)

    if rerank? do
      rerank_hits(query_text, rows, top_k)
    else
      Enum.map(rows, &to_hit/1)
    end
  end

  defp rerank_candidates, do: Application.get_env(:retrieval_node, :rerank_candidates, 50)

  defp rerank_hits(_query_text, [], _top_k), do: []

  defp rerank_hits(query_text, rows, top_k) do
    ids = Enum.map(rows, & &1.chunk_id)

    content_by_id =
      Repo.all(from(c in Chunk, where: c.id in ^ids, select: {c.id, c.content}))
      |> Map.new()

    # A candidate whose content row is missing (deleted between the HybridQuery
    # read and this fetch) is dropped rather than crashed on.
    {rows, contents} =
      rows
      |> Enum.flat_map(fn row ->
        case Map.fetch(content_by_id, row.chunk_id) do
          {:ok, content} -> [{row, content}]
          :error -> []
        end
      end)
      |> Enum.unzip()

    score_and_rank(query_text, rows, contents, top_k)
  end

  # Public (not `defp`) and @doc false purely so SearchTest can exercise the
  # empty-candidates guard directly — the scenario it guards (every
  # candidate's content row vanishing between the HybridQuery read in
  # hybrid_search/2 and the content fetch in rerank_hits/3 above) isn't
  # cleanly reproducible through the public API without racing a delete
  # against this function's own Repo call. Not part of this context's public
  # API.
  #
  # `rows` and `contents` are always the same length here (built together by
  # rerank_hits/3's Enum.unzip), so an empty `contents` means every candidate
  # was dropped. The real NxServingImpl backing Reranking.rerank_scores/2
  # forwards its passages list straight to Nx.Serving.batched_run, which
  # raises on an empty batch — so this returns before calling it rather than
  # handing it `[]`.
  @doc false
  @spec score_and_rank(String.t(), [map()], [String.t()], pos_integer()) :: [hit]
  def score_and_rank(_query_text, _rows, [] = _contents, _top_k), do: []

  def score_and_rank(query_text, rows, contents, top_k) do
    scores = Reranking.rerank_scores(query_text, contents)

    rows
    |> Enum.zip(scores)
    |> Enum.sort_by(fn {_row, score} -> score end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {row, score} -> to_hit(row, score) end)
  end

  defp to_hit(row, rerank_score) do
    row
    |> to_hit()
    |> Map.put(:score, rerank_score)
    |> Map.put(:fused_score, row.fused_score)
  end

  defp to_hit(%{fused_score: score} = row) do
    %{
      chunk: %{
        id: row.chunk_id,
        source_type: row.source_type,
        repo: row.repo,
        lang: row.lang,
        context_breadcrumb: row.context_breadcrumb,
        metadata: row.metadata
      },
      score: score
    }
  end
end
