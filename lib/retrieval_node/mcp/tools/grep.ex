defmodule RetrievalNode.MCP.Tools.Grep do
  @moduledoc """
  Literal/regex grep across an indexed git repo's tracked files at HEAD. With no
  `repo`, greps every indexed git repo. Returns `{repo, path, line, text}` matches.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.GitMirror

  # Aggregate cap across repos (GitMirror bounds per-file). Keeps a broad pattern on
  # an unauthenticated endpoint from buffering/returning the whole codebase.
  @max_matches 500

  # Match-everything patterns that would dump the codebase — rejected outright.
  @blocked_patterns ["", ".", ".*", ".+", ".*.*"]

  schema do
    field(:pattern, :string, required: true, description: "git grep pattern (POSIX regex)")
    field(:repo, :string, description: "Repo slug to search; omit to search all indexed repos")
  end

  @impl true
  def execute(%{pattern: pattern} = params, frame) do
    if String.trim(pattern) in @blocked_patterns do
      reply_error("pattern is too broad — provide a more specific pattern", frame)
    else
      run(pattern, Map.get(params, :repo), frame)
    end
  end

  defp run(pattern, repo, frame) do
    with {:ok, slugs} <- slugs(repo),
         {:ok, matches} <- grep_all(slugs, pattern) do
      capped = Enum.take(matches, @max_matches)
      payload = %{matches: capped, truncated: length(matches) > @max_matches}
      {:reply, Response.json(Response.tool(), payload), frame}
    else
      {:error, reason} -> reply_error(format_error(reason), frame)
    end
  end

  defp slugs(nil), do: {:ok, Ingest.git_repo_slugs()}

  defp slugs(repo) do
    with {:ok, slug} <- Ingest.resolve_git_repo(repo), do: {:ok, [slug]}
  end

  # Halt on the first grep error (e.g. an invalid pattern → git grep exit 2) so it
  # surfaces to the caller; stop early once the aggregate cap is reached so a
  # repo-less grep can't keep buffering across every repo.
  defp grep_all(slugs, pattern) do
    Enum.reduce_while(slugs, {:ok, []}, fn slug, {:ok, acc} ->
      if length(acc) >= @max_matches,
        do: {:halt, {:ok, acc}},
        else: grep_step(slug, pattern, acc)
    end)
  end

  defp grep_step(slug, pattern, acc) do
    case GitMirror.grep(slug, pattern) do
      {:ok, matches} -> {:cont, {:ok, acc ++ matches}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reply_error(msg, frame), do: {:reply, Response.error(Response.tool(), msg), frame}

  defp format_error(:repo_not_found), do: "repo not found (see list_repos)"
  defp format_error(:invalid_ref), do: "invalid ref"
  defp format_error(:git_timeout), do: "grep timed out — narrow the pattern"
  defp format_error({:git, _code, _out}), do: "grep failed — check the pattern is a valid regex"
  defp format_error(reason), do: "grep failed: #{inspect(reason)}"
end
