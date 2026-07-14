defmodule RetrievalNode.MCP.Tools.SemanticSearch do
  @moduledoc """
  Hybrid semantic + keyword search across indexed code, Jira issues, and Drive
  docs. Returns ranked back-links — `{source_type, repo, breadcrumb, metadata,
  score}` — **not** full content; expand a hit with `get_file`.
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
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    opts =
      [
        source_type: params |> Map.get(:source) |> normalize_source(),
        repo: Map.get(params, :repo),
        lang: Map.get(params, :lang)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    results = query |> Search.hybrid_search(opts) |> Enum.map(&result/1)
    {:reply, Response.json(Response.tool(), %{results: results}), frame}
  end

  defp normalize_source(nil), do: nil
  defp normalize_source(source), do: Map.get(@source_map, source, source)

  defp result(%{chunk: chunk, score: score}) do
    %{
      chunk_id: chunk.id,
      source_type: chunk.source_type,
      repo: chunk.repo,
      lang: chunk.lang,
      breadcrumb: chunk.context_breadcrumb,
      metadata: chunk.metadata,
      score: score
    }
  end
end
