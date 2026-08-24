defmodule RetrievalNode.MCP.Tools.SemanticSearch do
  @moduledoc """
  Hybrid semantic + keyword search across indexed code, Jira issues, and Drive
  docs. Returns ranked back-links — `{source_type, repo, breadcrumb, metadata,
  score}` — **not** full content; expand a hit with `get_file`.

  Optional `rerank: true` reranks the top RRF candidates with a cross-encoder
  for higher precision at the cost of latency (off by default). When active,
  each result also carries `fused_score` — the original RRF score — alongside
  the rerank `score`, for comparing the two ranking modes.

  Optional `graph: true` fuses a third ranking leg that matches the query's
  significant terms against code-graph entities (functions/classes/modules
  extracted from ASTs) and follows their mentions back to a chunk — surfaces
  a chunk reachable only through a symbol match, not just vector/keyword
  similarity (off by default).
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Search

  # Friendly shorthands the caller may pass for `source`, mapped to the DB enum.
  @source_map %{"git" => "git_repo", "jira" => "jira_project", "drive" => "drive_folder"}

  schema do
    field(:query, :string, required: true, description: "Natural-language or keyword query")
    field(:source, :string, description: "Filter by source kind: git | jira | drive")
    field(:repo, :string, description: "Filter by repo slug (see list_repos)")
    field(:lang, :string, description: "Filter by language, e.g. python, elixir")

    field(:rerank, :boolean,
      description:
        "Rerank top candidates with a cross-encoder for higher precision (slower; default off)"
    )

    field(:graph, :boolean,
      description:
        "Fuse code-graph symbol matches into ranking (entities extracted from ASTs; default off)"
    )
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    case normalize_source(Map.get(params, :source)) do
      {:ok, source_type} ->
        opts =
          [
            source_type: source_type,
            repo: Map.get(params, :repo),
            lang: Map.get(params, :lang),
            rerank: Map.get(params, :rerank),
            graph: Map.get(params, :graph)
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        results = query |> Search.hybrid_search(opts) |> Enum.map(&result/1)
        {:reply, Response.json(Response.tool(), %{results: results}), frame}

      {:error, msg} ->
        {:reply, Response.error(Response.tool(), msg), frame}
    end
  end

  # Reject an unknown `source` rather than silently returning zero results.
  defp normalize_source(nil), do: {:ok, nil}

  defp normalize_source(source) when is_map_key(@source_map, source),
    do: {:ok, @source_map[source]}

  defp normalize_source(other),
    do: {:error, "unknown source #{inspect(other)} — use git | jira | drive"}

  defp result(hit) do
    %{
      chunk_id: hit.chunk.id,
      source_type: hit.chunk.source_type,
      repo: hit.chunk.repo,
      lang: hit.chunk.lang,
      breadcrumb: hit.chunk.context_breadcrumb,
      metadata: hit.chunk.metadata,
      score: hit.score
    }
    |> maybe_put_fused_score(hit)
  end

  defp maybe_put_fused_score(result, %{fused_score: fused_score}),
    do: Map.put(result, :fused_score, fused_score)

  defp maybe_put_fused_score(result, _hit), do: result
end
