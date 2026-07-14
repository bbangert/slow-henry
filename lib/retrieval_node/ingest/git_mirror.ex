defmodule RetrievalNode.Ingest.GitMirror do
  @moduledoc """
  Thin, safe facade over local **bare mirror** git repos — the single place git
  is shelled out to (the MCP tool modules never call git directly).

  Safety rules (design-mcp.md): every call uses `System.cmd/3`'s **argument-list**
  form (no shell string, so no injection); `git`/`rg` presence is checked up front;
  a repo slug is resolved through `Path.safe_relative/1` into the mirror root (no
  traversal to arbitrary dirs); and `show/3`'s path is `Path.safe_relative/1`-guarded
  before it reaches `git show`. Errors surface as `{:error, reason}` tuples at this
  boundary so callers never need a bare rescue.

  A bare `--mirror` clone keeps refs without a working tree; `git ls-tree`/`diff`/
  `show`/`grep` all operate against a ref, which is exactly what incremental sync
  and the `grep`/`get_file` MCP tools need.
  """

  @type repo :: String.t()
  @type reason :: :git_not_found | :invalid_repo | :invalid_path | {:git, integer(), String.t()}

  @doc "Root directory holding the `<slug>.git` bare mirrors."
  @spec mirror_root() :: String.t()
  def mirror_root do
    Application.get_env(
      :retrieval_node,
      :git_mirror_root,
      Path.join(System.tmp_dir!(), "rn-git-mirrors")
    )
  end

  @doc "Absolute path to a repo's bare mirror, or `{:error, :invalid_repo}` on traversal."
  @spec mirror_path(repo) :: {:ok, String.t()} | {:error, :invalid_repo}
  def mirror_path(slug) do
    case Path.safe_relative(slug <> ".git") do
      {:ok, rel} -> {:ok, Path.join(mirror_root(), rel)}
      :error -> {:error, :invalid_repo}
    end
  end

  @doc """
  Ensure a mirror exists and is current: `git clone --mirror` if absent, else
  `git fetch --prune`. `url` may be any git-cloneable location (incl. a local path).
  """
  @spec ensure_mirror(repo, String.t()) :: {:ok, String.t()} | {:error, reason}
  def ensure_mirror(slug, url) do
    with {:ok, path} <- mirror_path(slug),
         {:ok, _out} <- clone_or_fetch(path, url) do
      {:ok, path}
    end
  end

  defp clone_or_fetch(path, url) do
    if File.dir?(path) do
      git(["--git-dir", path, "fetch", "--prune", "origin"])
    else
      File.mkdir_p!(mirror_root())
      git(["clone", "--mirror", url, path])
    end
  end

  @doc "Resolve a ref (default HEAD) to its commit sha."
  @spec head_sha(repo, String.t()) :: {:ok, String.t()} | {:error, reason}
  def head_sha(slug, ref \\ "HEAD") do
    with {:ok, path} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", path, "rev-parse", ref]) do
      {:ok, String.trim(out)}
    end
  end

  @doc """
  Files changed between two shas. With `old_sha == nil` (first sync) returns every
  file at `new_sha` (`ls-tree`); otherwise the `diff --name-only` between them.
  """
  @spec changed_files(repo, String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | {:error, reason}
  def changed_files(slug, nil, new_sha) do
    with {:ok, path} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", path, "ls-tree", "-r", "--name-only", new_sha]) do
      {:ok, lines(out)}
    end
  end

  def changed_files(slug, old_sha, new_sha) do
    with {:ok, path} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", path, "diff", "--name-only", old_sha, new_sha]) do
      {:ok, lines(out)}
    end
  end

  @doc "Return a file's exact bytes at `ref` (default HEAD). The sole full-content path."
  @spec show(repo, String.t(), String.t()) :: {:ok, String.t()} | {:error, reason}
  def show(slug, path, ref \\ "HEAD") do
    with {:ok, safe} <- safe_path(path),
         {:ok, gitdir} <- mirror_path(slug) do
      # git/1 already returns {:ok, content} | {:error, reason} — the with's value.
      git(["--git-dir", gitdir, "show", "#{ref}:#{safe}"])
    end
  end

  @doc """
  Grep a repo at `ref` (default HEAD). Returns `[%{repo, path, line, text}]`.
  Exit 1 (no matches) is a normal empty result, not an error.
  """
  @spec grep(repo, String.t(), String.t()) :: {:ok, [map()]} | {:error, reason}
  def grep(slug, pattern, ref \\ "HEAD") do
    with {:ok, gitdir} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", gitdir, "grep", "-n", "-e", pattern, ref], [0, 1]) do
      {:ok, parse_grep(slug, ref, out)}
    end
  end

  # --- internals ---

  # Run git with an argument list (no shell). `ok_codes` are non-error exit codes.
  defp git(args, ok_codes \\ [0]) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        {out, code} = System.cmd(git, args, stderr_to_stdout: true)
        if code in ok_codes, do: {:ok, out}, else: {:error, {:git, code, String.trim(out)}}
    end
  end

  defp safe_path(path) do
    case Path.safe_relative(path) do
      {:ok, rel} -> {:ok, rel}
      :error -> {:error, :invalid_path}
    end
  end

  defp lines(out) do
    out |> String.split("\n", trim: true)
  end

  # `git grep -n <ref>` lines look like "ref:path:line:text".
  defp parse_grep(slug, ref, out) do
    prefix = ref <> ":"

    out
    |> lines()
    |> Enum.flat_map(fn line ->
      line = String.replace_prefix(line, prefix, "")

      case String.split(line, ":", parts: 3) do
        [path, line_no, text] ->
          [%{repo: slug, path: path, line: String.to_integer(line_no), text: text}]

        _ ->
          []
      end
    end)
  end
end
