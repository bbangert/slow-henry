defmodule RetrievalNode.MCP.Tools.Grep do
  @moduledoc """
  Literal/regex grep across an indexed git repo's tracked files at HEAD. With no
  `repo`, greps every indexed git repo. Returns `{repo, path, line, text}` matches.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.GitMirror

  schema do
    field(:pattern, :string, required: true, description: "git grep pattern (POSIX regex)")
    field(:repo, :string, description: "Repo slug to search; omit to search all indexed repos")
  end

  @impl true
  def execute(%{pattern: pattern} = params, frame) do
    with {:ok, slugs} <- slugs(Map.get(params, :repo)),
         {:ok, matches} <- grep_all(slugs, pattern) do
      {:reply, Response.json(Response.tool(), %{matches: matches}), frame}
    else
      {:error, reason} -> {:reply, Response.error(Response.tool(), format_error(reason)), frame}
    end
  end

  defp slugs(nil), do: {:ok, Ingest.git_repo_slugs()}

  defp slugs(repo) do
    with {:ok, slug} <- Ingest.resolve_git_repo(repo), do: {:ok, [slug]}
  end

  # Halt on the first grep error (e.g. an invalid pattern → git grep exit 2) so it
  # surfaces to the caller rather than silently returning empty matches.
  defp grep_all(slugs, pattern) do
    Enum.reduce_while(slugs, {:ok, []}, fn slug, {:ok, acc} ->
      case GitMirror.grep(slug, pattern) do
        {:ok, matches} -> {:cont, {:ok, acc ++ matches}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp format_error(:repo_not_found), do: "repo not found (see list_repos)"
  defp format_error(:invalid_ref), do: "invalid ref"
  defp format_error({:git, _code, _out}), do: "grep failed — check the pattern is a valid regex"
  defp format_error(reason), do: "grep failed: #{inspect(reason)}"
end
