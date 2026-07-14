defmodule RetrievalNode.MCP.Tools.GetFile do
  @moduledoc """
  Fetch the exact bytes of a file at a ref from an indexed git repo — the sole
  full-content tool, and the companion to `semantic_search`/`grep` hits (so a hit
  and its fetch agree). Returns `{repo, path, ref, content}`.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.GitMirror

  schema do
    field(:repo, :string, required: true, description: "Repo slug (see list_repos)")
    field(:path, :string, required: true, description: "Repo-relative file path")
    field(:ref, :string, description: "Git ref or sha (default HEAD)")
  end

  @impl true
  def execute(%{repo: repo, path: path} = params, frame) do
    ref = Map.get(params, :ref) || "HEAD"

    with {:ok, slug} <- Ingest.resolve_git_repo(repo),
         {:ok, content} <- GitMirror.show(slug, path, ref) do
      payload = %{repo: slug, path: path, ref: ref, content: content}
      {:reply, Response.json(Response.tool(), payload), frame}
    else
      {:error, reason} -> {:reply, Response.error(Response.tool(), format_error(reason)), frame}
    end
  end

  defp format_error(:repo_not_found), do: "repo not found (see list_repos)"
  defp format_error(:invalid_path), do: "invalid path — path traversal is rejected"
  defp format_error(:invalid_ref), do: "invalid ref"
  defp format_error(:git_timeout), do: "get_file timed out"
  defp format_error(:file_too_large), do: "file too large to return"
  defp format_error({:git, _code, _out}), do: "file or ref not found"
  defp format_error(reason), do: "get_file failed: #{inspect(reason)}"
end
