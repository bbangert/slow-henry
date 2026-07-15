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
         {:ok, matches, truncated?} <- grep_all(slugs, pattern) do
      payload = %{matches: matches, truncated: truncated?}
      {:reply, Response.json(Response.tool(), payload), frame}
    else
      {:error, reason} -> reply_error(format_error(reason), frame)
    end
  end

  defp slugs(nil), do: {:ok, Ingest.git_repo_slugs()}

  defp slugs(repo) do
    with {:ok, slug} <- Ingest.resolve_git_repo(repo), do: {:ok, [slug]}
  end

  # Collect matches across repos, halting on the first grep error (so an invalid
  # pattern surfaces) and once the aggregate cap is reached (so a repo-less grep
  # can't keep buffering). Per-repo lists are prepended (O(1)) with a running count
  # — no `length/1` per repo, no `acc ++ matches` — and flattened once at the end.
  # `truncated?` is true iff we halted at the cap, or GitMirror.grep/3 itself
  # truncated a repo's own output (conservative: on the exactly-cap boundary it may
  # over-report, never under-report).
  defp grep_all(slugs, pattern) do
    slugs
    |> Enum.reduce_while({[], 0, false}, &grep_reduce(&1, pattern, &2))
    |> case do
      {:error, reason} -> {:error, reason}
      {:capped, chunks, _truncated?} -> {:ok, flatten_take(chunks), true}
      {chunks, _count, truncated?} -> {:ok, flatten_take(chunks), truncated?}
    end
  end

  defp grep_reduce(slug, pattern, {chunks, count, truncated?}) do
    case GitMirror.grep(slug, pattern) do
      {:ok, matches, repo_truncated?} ->
        accumulate(matches, chunks, count, truncated? or repo_truncated?)

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # Prepend this repo's matches (O(1)) and halt once the aggregate cap is reached.
  defp accumulate(matches, chunks, count, truncated?) do
    count = count + length(matches)
    chunks = [matches | chunks]

    if count >= @max_matches,
      do: {:halt, {:capped, chunks, truncated?}},
      else: {:cont, {chunks, count, truncated?}}
  end

  defp flatten_take(chunks),
    do: chunks |> Enum.reverse() |> Enum.concat() |> Enum.take(@max_matches)

  defp reply_error(msg, frame), do: {:reply, Response.error(Response.tool(), msg), frame}

  defp format_error(:repo_not_found), do: "repo not found (see list_repos)"
  defp format_error(:invalid_ref), do: "invalid ref"
  defp format_error(:git_timeout), do: "grep timed out — narrow the pattern"
  defp format_error({:git, _code, _out}), do: "grep failed — check the pattern is a valid regex"
  defp format_error(reason), do: "grep failed: #{inspect(reason)}"
end
