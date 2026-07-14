defmodule RetrievalNode.Ingest.GitMirror do
  @moduledoc """
  Thin, safe facade over local **bare mirror** git repos — the single place git
  is shelled out to (the MCP tool modules never call git directly).

  Safety (design-mcp.md + Phase 6a review). Inputs (`slug`, `path`, `pattern`,
  `ref`, `url`) come from UNTRUSTED MCP callers, so:

    * **No shell** — every call uses `System.cmd/3`'s argument-list form.
    * **No git option injection** — git parses `-`-prefixed operands as flags even
      without a shell. Every `ref`/`sha` is validated (`safe_ref/1`: no leading
      dash, alphanumeric start, no `:`), and `--end-of-options` precedes ref/sha/url
      operands where git supports it (all but `grep`, which relies on validation).
    * **No path/repo traversal** — `Path.safe_relative/1` on the repo slug and on the
      `show` file path.
    * **Transport allowlist** on the clone `url` (blocks `ext::sh -c …` RCE).
    * **Bounded output** — `show` refuses files over `#{5_000_000}` bytes.

  Errors surface as `{:error, reason}` tuples so callers need no bare rescue.
  """

  @type repo :: String.t()
  @type reason ::
          :git_not_found
          | :invalid_repo
          | :invalid_path
          | :invalid_ref
          | :invalid_url
          | :file_too_large
          | {:git, integer(), String.t()}

  # A ref/sha that cannot be mistaken for a git option: alphanumeric start, then
  # word chars / dot / slash / dash. Excludes a leading `-`, `:`, `=`, `~`, `^`,
  # whitespace — so a validated ref can never be `--output=…` / `--open-files-in-pager=…`.
  @ref_re ~r/\A[0-9A-Za-z][0-9A-Za-z._\/-]*\z/
  @allowed_url_schemes ~w(https:// http:// ssh:// git:// file://)
  @max_file_bytes 5_000_000

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
  `git fetch --prune`. `url` must use an allowlisted transport.
  """
  @spec ensure_mirror(repo, String.t()) :: {:ok, String.t()} | {:error, reason}
  def ensure_mirror(slug, url) do
    with {:ok, path} <- mirror_path(slug),
         {:ok, safe_url} <- safe_url(url),
         {:ok, _out} <- clone_or_fetch(path, safe_url) do
      {:ok, path}
    end
  end

  defp clone_or_fetch(path, url) do
    if File.dir?(path) do
      git(["--git-dir", path, "fetch", "--prune", "origin"])
    else
      File.mkdir_p!(mirror_root())
      git(["clone", "--mirror", "--end-of-options", url, path])
    end
  end

  @doc "Resolve a ref (default HEAD) to its commit sha."
  @spec head_sha(repo, String.t()) :: {:ok, String.t()} | {:error, reason}
  def head_sha(slug, ref \\ "HEAD") do
    with {:ok, ref} <- safe_ref(ref),
         {:ok, path} <- mirror_path(slug),
         # `--verify` makes rev-parse emit only the resolved sha (plain rev-parse
         # echoes the --end-of-options token itself).
         {:ok, out} <- git(["--git-dir", path, "rev-parse", "--verify", "--end-of-options", ref]) do
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
    with {:ok, new_sha} <- safe_ref(new_sha),
         {:ok, path} <- mirror_path(slug),
         {:ok, out} <-
           git(["--git-dir", path, "ls-tree", "-r", "--name-only", "--end-of-options", new_sha]) do
      {:ok, lines(out)}
    end
  end

  def changed_files(slug, old_sha, new_sha) do
    with {:ok, old_sha} <- safe_ref(old_sha),
         {:ok, new_sha} <- safe_ref(new_sha),
         {:ok, path} <- mirror_path(slug),
         {:ok, out} <-
           git(["--git-dir", path, "diff", "--name-only", "--end-of-options", old_sha, new_sha]) do
      {:ok, lines(out)}
    end
  end

  @doc "Return a file's exact bytes at `ref` (default HEAD). The sole full-content path."
  @spec show(repo, String.t(), String.t()) :: {:ok, String.t()} | {:error, reason}
  def show(slug, path, ref \\ "HEAD") do
    with {:ok, ref} <- safe_ref(ref),
         {:ok, safe} <- safe_path(path),
         {:ok, gitdir} <- mirror_path(slug),
         :ok <- check_size(gitdir, "#{ref}:#{safe}") do
      git(["--git-dir", gitdir, "show", "--end-of-options", "#{ref}:#{safe}"])
    end
  end

  @doc """
  Grep a repo at `ref` (default HEAD). Returns `[%{repo, path, line, text}]`.
  Exit 1 (no matches) is a normal empty result. `-I` skips binary files.
  """
  @spec grep(repo, String.t(), String.t()) :: {:ok, [map()]} | {:error, reason}
  def grep(slug, pattern, ref \\ "HEAD") do
    # git grep doesn't accept --end-of-options; the validated ref (no leading dash)
    # is what prevents it being read as an option, and `-e` guards the pattern.
    with {:ok, ref} <- safe_ref(ref),
         {:ok, gitdir} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", gitdir, "grep", "-n", "-I", "-e", pattern, ref], [0, 1]) do
      {:ok, parse_grep(slug, ref, out)}
    end
  end

  # --- internals ---

  defp git(args, ok_codes \\ [0]) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        {out, code} = System.cmd(git, args, stderr_to_stdout: true)
        if code in ok_codes, do: {:ok, out}, else: {:error, {:git, code, String.trim(out)}}
    end
  end

  defp safe_ref(ref) when is_binary(ref) do
    if Regex.match?(@ref_re, ref), do: {:ok, ref}, else: {:error, :invalid_ref}
  end

  defp safe_ref(_), do: {:error, :invalid_ref}

  defp safe_path(path) do
    case Path.safe_relative(path) do
      {:ok, rel} -> {:ok, rel}
      :error -> {:error, :invalid_path}
    end
  end

  # Allowlist clone transports; reject `-`-prefixed and `::` (git ext/transport
  # helpers like `ext::sh -c …`, which are an RCE vector).
  defp safe_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "-") -> {:error, :invalid_url}
      String.contains?(url, "::") -> {:error, :invalid_url}
      scp_like?(url) -> {:ok, url}
      Enum.any?(@allowed_url_schemes, &String.starts_with?(url, &1)) -> {:ok, url}
      true -> {:error, :invalid_url}
    end
  end

  defp safe_url(_), do: {:error, :invalid_url}

  defp scp_like?(url), do: Regex.match?(~r/\A[\w.-]+@[\w.-]+:/, url)

  # Refuse to buffer an oversized blob into memory (`git show` has no size limit).
  defp check_size(gitdir, object) do
    case git(["--git-dir", gitdir, "cat-file", "-s", "--end-of-options", object]) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {size, _} when size > @max_file_bytes -> {:error, :file_too_large}
          _ -> :ok
        end

      # A missing object/ref here surfaces as the same git error from `show`.
      {:error, _} ->
        :ok
    end
  end

  defp lines(out), do: String.split(out, "\n", trim: true)

  # `git grep -n <ref>` lines look like "ref:path:line:text". Fall through to []
  # on any line that doesn't parse (e.g. an unexpected non-numeric field) rather
  # than raising, honoring the "always {:ok, _} | {:error, _}" contract.
  defp parse_grep(slug, ref, out) do
    prefix = ref <> ":"

    out
    |> lines()
    |> Enum.flat_map(fn line ->
      with stripped <- String.replace_prefix(line, prefix, ""),
           [path, line_no, text] <- String.split(stripped, ":", parts: 3),
           {n, ""} <- Integer.parse(line_no) do
        [%{repo: slug, path: path, line: n, text: text}]
      else
        _ -> []
      end
    end)
  end
end
