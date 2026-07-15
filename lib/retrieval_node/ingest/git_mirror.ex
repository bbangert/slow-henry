defmodule RetrievalNode.Ingest.GitMirror do
  @moduledoc """
  Thin, safe facade over local **bare mirror** git repos — the single place git
  is shelled out to (the MCP tool modules never call git directly).

  Safety (design-mcp.md + Phase 6a review). Inputs (`slug`, `path`, `pattern`,
  `ref`, `url`) come from UNTRUSTED MCP callers, so:

    * **No shell** — every call uses `System.cmd/3`'s argument-list form (`grep`
      instead streams via a raw `Port` in the same argument-list form — see
      `grep/3` — to bound memory on a large result set).
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
          | :git_timeout
          | :empty_repo
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

  # sobelow: `path`/`mirror_root()` are derived via mirror_path/1's
  # Path.safe_relative/1 validation on the caller-supplied slug — see
  # reviews/p6a-security.md.
  # sobelow_skip ["Traversal.FileModule"]
  defp clone_or_fetch(path, url) do
    # Network ops legitimately take much longer than a local object-DB read, so they
    # use the longer network_timeout rather than the short MCP-facing default.
    if File.dir?(path) do
      git(["--git-dir", path, "fetch", "--prune", "origin"], [0], network_timeout())
    else
      File.mkdir_p!(mirror_root())
      git(["clone", "--mirror", "--end-of-options", url, path], [0], network_timeout())
    end
  end

  @doc """
  Resolve a ref (default HEAD) to its commit sha. A brand-new repo with no
  commits yet has no `HEAD` to resolve — `rev-parse --verify HEAD` exits 128 on
  that unborn-branch state, which is a normal, deterministic outcome (not a git
  failure) so it's classified separately as `{:error, :empty_repo}` rather than
  the raw `{:git, 128, _}` tuple, letting callers no-op instead of retrying
  forever. Only checked for the default `ref == "HEAD"` case — an explicit,
  unresolvable custom ref against a non-empty repo is still a plain git error.
  """
  @spec head_sha(repo, String.t()) :: {:ok, String.t()} | {:error, reason}
  def head_sha(slug, ref \\ "HEAD") do
    with {:ok, ref} <- safe_ref(ref),
         {:ok, path} <- mirror_path(slug) do
      # `--verify` makes rev-parse emit only the resolved sha (plain rev-parse
      # echoes the --end-of-options token itself).
      case git(["--git-dir", path, "rev-parse", "--verify", "--end-of-options", ref]) do
        {:ok, out} -> {:ok, String.trim(out)}
        {:error, {:git, _code, _msg} = reason} -> unresolvable_head(path, ref, reason)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp unresolvable_head(path, "HEAD", reason) do
    if empty_repo?(path), do: {:error, :empty_repo}, else: {:error, reason}
  end

  defp unresolvable_head(_path, _ref, reason), do: {:error, reason}

  # Robust "is this repo empty" probe: `--count --all` over every ref (not just
  # HEAD) is 0 only when the object DB genuinely has no commits reachable from
  # anywhere — a repo with commits on some other branch but a detached/missing
  # HEAD is a different (still-erroring) situation, not this one.
  defp empty_repo?(path) do
    case git(["--git-dir", path, "rev-list", "--count", "--all"]) do
      {:ok, out} -> String.trim(out) == "0"
      _ -> false
    end
  end

  @doc """
  Files changed between two shas. With `old_sha == nil` (first sync) returns every
  file at `new_sha` (`ls-tree`); otherwise the `diff --raw` between them.

  Both variants are **blob-only**: a gitlink entry (a submodule reference, mode
  `160000`) points at a commit object in a different repo entirely, not a blob in
  this one — `show/3` has nothing to read there (`git show HEAD:<path>` exits
  non-zero). `ls-tree`'s type column and `diff --raw`'s mode columns are what let
  us tell a gitlink from a real file (`--name-only`/`--name-status` alone can't),
  so submodules are filtered out here, before any caller ever tries to fetch one.
  """
  @spec changed_files(repo, String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | {:error, reason}
  def changed_files(slug, nil, new_sha) do
    with {:ok, new_sha} <- safe_ref(new_sha),
         {:ok, path} <- mirror_path(slug),
         {:ok, out} <- git(["--git-dir", path, "ls-tree", "-r", "--end-of-options", new_sha]) do
      {:ok, parse_ls_tree(lines(out))}
    end
  end

  def changed_files(slug, old_sha, new_sha) do
    with {:ok, entries} <- diff_raw_entries(slug, old_sha, new_sha) do
      {:ok, Enum.map(entries, &entry_path/1)}
    end
  end

  @doc """
  Like `changed_files/3` but tags each path with its change status so callers can
  tell a **true deletion** from a still-present file. First sync (`old_sha == nil`)
  is every file as `:added`; otherwise `diff --raw` (a rename `R` becomes
  `:deleted` old + `:added` new, a copy `C` becomes `:added` new). Gitlink
  (submodule) entries are filtered out — see `changed_files/3`.
  """
  @spec changed_entries(repo, String.t() | nil, String.t()) ::
          {:ok, [{:added | :modified | :deleted, String.t()}]} | {:error, reason}
  def changed_entries(slug, nil, new_sha) do
    with {:ok, files} <- changed_files(slug, nil, new_sha) do
      {:ok, Enum.map(files, &{:added, &1})}
    end
  end

  def changed_entries(slug, old_sha, new_sha) do
    with {:ok, entries} <- diff_raw_entries(slug, old_sha, new_sha) do
      {:ok, Enum.flat_map(entries, &entry_statuses/1)}
    end
  end

  defp diff_raw_entries(slug, old_sha, new_sha) do
    with {:ok, old_sha} <- safe_ref(old_sha),
         {:ok, new_sha} <- safe_ref(new_sha),
         {:ok, path} <- mirror_path(slug),
         {:ok, out} <-
           git(["--git-dir", path, "diff", "--raw", "--end-of-options", old_sha, new_sha]) do
      {:ok, parse_diff_raw(lines(out))}
    end
  end

  # ls-tree (no --name-only) line: `<mode> <type> <sha>\t<path>`. `-r` already
  # recurses into subtrees, so the only types seen are `blob` (a real file) and
  # `commit` (a gitlink/submodule) — never `tree`.
  defp parse_ls_tree(lines) do
    Enum.flat_map(lines, &ls_tree_line/1)
  end

  defp ls_tree_line(line) do
    case String.split(line, "\t") do
      [meta, path] -> ls_tree_entry(meta, path)
      _ -> []
    end
  end

  defp ls_tree_entry(meta, path) do
    case String.split(meta, " ", trim: true) do
      [_mode, "blob", _sha] -> [path]
      _ -> []
    end
  end

  # --raw line: `:<old_mode> <new_mode> <old_sha> <new_sha> <status>[score]\t<path>`
  # (rename/copy: a second `\t<new_path>` column). Entries where either mode is a
  # gitlink (160000) are dropped outright — on either side of a rename/copy too,
  # since a "submodule renamed to submodule" is still nothing `show/3` can read.
  defp parse_diff_raw(lines) do
    Enum.flat_map(lines, fn line ->
      case String.split(line, "\t") do
        [meta, path] -> raw_entry(meta, path, path)
        [meta, old_path, new_path] -> raw_entry(meta, old_path, new_path)
        _ -> []
      end
    end)
  end

  defp raw_entry(meta, old_path, new_path) do
    case meta |> String.trim_leading(":") |> String.split(" ", trim: true) do
      [old_mode, new_mode, _old_sha, _new_sha, status] ->
        if old_mode == "160000" or new_mode == "160000" do
          []
        else
          [{status, old_path, new_path}]
        end

      _ ->
        []
    end
  end

  # D has no "new" side to point at; every other status (A/M/R/C) reports the
  # current (new) path — matching plain `diff --name-only`'s behavior for renames
  # (only the new path is listed).
  defp entry_path({"D", old_path, _new_path}), do: old_path
  defp entry_path({_status, _old_path, new_path}), do: new_path

  defp entry_statuses({"D", old_path, _new_path}), do: [{:deleted, old_path}]

  defp entry_statuses({<<"R", _::binary>>, old_path, new_path}),
    do: [{:deleted, old_path}, {:added, new_path}]

  defp entry_statuses({<<"C", _::binary>>, _old_path, new_path}), do: [{:added, new_path}]
  defp entry_statuses({_status, _old_path, new_path}), do: [{:modified, new_path}]

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
  Grep a repo at `ref` (default HEAD). Returns `{:ok, matches, truncated?}` where
  `matches` is `[%{repo, path, line, text}]`. Exit 1 (no matches) is a normal
  empty result. `-I` skips binary files.

  Output is streamed through a raw `Port` rather than buffered via `System.cmd`:
  `System.cmd`'s `into:` can't abort a `Collectable` mid-stream, so a common
  pattern across a big repo could spike memory well before the MCP tool layer's
  aggregate cap ever sees it. Collection stops early once `grep_max_bytes` or
  `grep_max_matches` (both config-overridable) is exceeded; `Port.close/1` alone
  only detaches Erlang from the pipe — git keeps walking the tree until its next
  stdout write hits SIGPIPE, which can lag arbitrarily, so the underlying OS
  process is also sent `SIGKILL` directly (see `kill_os_pid/1`). Only *complete*
  `<ref>:<path>\\0<lineno>\\0<text>` records — never one cut mid-write by the
  budget — are parsed; `truncated?` is `true` whenever that happened.
  """
  # Per-file match cap (`-m`) so one huge file can't dump unbounded output; the tool
  # layer caps the aggregate across repos too.
  @grep_max_per_file 100

  # Streaming budgets for a single grep/3 call. `grep_max_matches` defaults to the
  # MCP tool layer's own aggregate cap (RetrievalNode.MCP.Tools.Grep's @max_matches)
  # — a single repo's grep has no reason to buffer more than the tool layer will
  # ever keep. Budgets are checked between Port chunks (not mid-chunk), so the
  # actual bytes/matches collected before stopping can run a bit over either
  # number; that's fine — the tool layer applies its own hard `Enum.take` cap.
  @default_grep_max_bytes 1_000_000
  @default_grep_max_matches 500
  @grep_ok_codes [0, 1]

  @spec grep(repo, String.t(), String.t()) ::
          {:ok, [map()], boolean()} | {:error, reason}
  def grep(slug, pattern, ref \\ "HEAD") do
    # git grep doesn't accept --end-of-options; the validated ref (no leading dash)
    # is what prevents it being read as an option, and `-e` guards the pattern.
    # `-z` NUL-delimits fields so a `:` in a file path can't corrupt parsing.
    with {:ok, ref} <- safe_ref(ref),
         {:ok, gitdir} <- mirror_path(slug),
         {:ok, git} <- find_git(),
         {:ok, out, truncated?} <-
           run_grep(
             git,
             ["--git-dir", gitdir, "grep", "-n", "-I", "-z", "-m", "#{@grep_max_per_file}"] ++
               ["-e", pattern, ref]
           ) do
      {:ok, parse_grep(slug, ref, out), truncated?}
    end
  end

  # --- internals ---

  # Hard ceiling on a single git invocation. A pathological pattern/tree can make git
  # run unbounded; without this the caller (and the MCP session process) would hang.
  # On timeout the task is killed (closing the port) and the underlying OS process is
  # explicitly SIGKILLed (see kill_os_pid/1) — Port.close/1 alone doesn't signal it,
  # and git only dies on its next stdout write (SIGPIPE), which can lag arbitrarily.
  # The default is short (bounds the untrusted MCP-facing grep/show); network ops
  # (clone/fetch) pass `network_timeout/0`, which is legitimately slow. Both are
  # config-overridable.
  @default_git_timeout :timer.seconds(20)
  @default_git_network_timeout :timer.minutes(10)

  defp default_timeout,
    do: Application.get_env(:retrieval_node, :git_timeout_ms, @default_git_timeout)

  defp network_timeout,
    do:
      Application.get_env(:retrieval_node, :git_network_timeout_ms, @default_git_network_timeout)

  defp git(args, ok_codes \\ [0], timeout \\ default_timeout()) do
    with {:ok, git} <- find_git(), do: run_git(git, args, ok_codes, timeout)
  end

  defp find_git do
    case System.find_executable("git") do
      nil -> {:error, :git_not_found}
      git -> {:ok, git}
    end
  end

  # Shared by run_git/4 (buffered) and run_grep/2 (streaming): opens git as a raw
  # Port and captures its OS pid so an early-termination path (grep budget, or a
  # git_timeout on either) can SIGKILL the process directly — see the module doc
  # / @default_git_timeout comment for why Port.close/1 alone isn't enough.
  defp open_git_port(git, args) do
    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        :stderr_to_stdout,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {port, os_pid}
  end

  # exec_git/4 and stream_grep/4 send `{:git_os_pid, ref, os_pid}` to `parent`
  # right after opening their port — before doing any further work — so it's
  # already in the mailbox by the time Task.yield/2 returns, whichever branch it
  # returns on. `ref` (made fresh per call) is what keeps this from ever matching
  # a message left over from some other concurrent git op the same process
  # happens to be running.
  defp flush_os_pid_message(ref) do
    receive do
      {:git_os_pid, ^ref, _os_pid} -> :ok
    after
      0 -> :ok
    end
  end

  # Timeout counterpart to flush_os_pid_message/1: same drain, but kills what it
  # finds. The `after 100` is a safety margin, not something normal runs rely on
  # — with a non-trivial timeout the message is long since delivered by the time
  # we get here. With a near-zero timeout (see the "timeouts are per-command"
  # test) the port may not have even spawned yet; os_pid is then `nil` and
  # kill_os_pid/1 is a no-op.
  defp kill_pending_os_pid(ref) do
    receive do
      {:git_os_pid, ^ref, os_pid} -> kill_os_pid(os_pid)
    after
      100 -> :ok
    end
  end

  # os_pid comes straight from Port.info/2, never from attacker input, so there's
  # no shell/argument-injection surface here; a failed/nonzero kill (pid already
  # exited, or we lost the race) is a no-op we deliberately ignore.
  # sobelow_skip ["CI.System"]
  defp kill_os_pid(nil), do: :ok

  defp kill_os_pid(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # sobelow: argument-list Port.open only (no shell); every ref/sha/url operand
  # is validated by safe_ref/1 or safe_url/1 before reaching git/4 — see
  # reviews/p6a-security.md and reviews/p7-security.md.
  # sobelow_skip ["CI.System"]
  defp run_git(git, args, ok_codes, timeout) do
    parent = self()
    ref = make_ref()
    task = Task.async(fn -> exec_git(git, args, parent, ref) end)

    case Task.yield(task, timeout) do
      {:ok, {out, code}} ->
        flush_os_pid_message(ref)
        if code in ok_codes, do: {:ok, out}, else: {:error, {:git, code, String.trim(out)}}

      # nil = still running (timed out); {:exit, _} = the task crashed. Either way
      # kill the task (closing the port) and explicitly SIGKILL the OS process —
      # closing the port alone doesn't terminate git promptly enough (see grep/3
      # doc and @default_git_timeout above).
      _ ->
        Task.shutdown(task, :brutal_kill)
        kill_pending_os_pid(ref)
        {:error, :git_timeout}
    end
  end

  # Runs `git` to completion, buffering its output — the non-streaming
  # counterpart to stream_grep/4.
  defp exec_git(git, args, parent, ref) do
    {port, os_pid} = open_git_port(git, args)
    send(parent, {:git_os_pid, ref, os_pid})
    collect_git(port, [])
  end

  defp collect_git(port, chunks) do
    receive do
      {^port, {:data, chunk}} -> collect_git(port, [chunk | chunks])
      {^port, {:exit_status, status}} -> {raw_output(chunks), status}
    end
  end

  # `grep`'s streaming counterpart to `run_git/4`. Same Task.async/yield/shutdown
  # + os_pid SIGKILL wrapper on timeout, but the task body reads the Port itself
  # (via stream_grep/4 / grep_receive/5) instead of buffering to completion, so
  # it can also stop early — and SIGKILL — on a byte/match budget.
  defp run_grep(git, args) do
    parent = self()
    ref = make_ref()
    task = Task.async(fn -> stream_grep(git, args, parent, ref) end)

    case Task.yield(task, default_timeout()) do
      {:ok, result} ->
        flush_os_pid_message(ref)
        result

      _ ->
        Task.shutdown(task, :brutal_kill)
        kill_pending_os_pid(ref)
        {:error, :git_timeout}
    end
  end

  defp stream_grep(git, args, parent, ref) do
    {port, os_pid} = open_git_port(git, args)
    send(parent, {:git_os_pid, ref, os_pid})
    grep_receive(port, os_pid, [], 0, 0)
  end

  defp grep_receive(port, os_pid, chunks, total_bytes, total_matches) do
    receive do
      {^port, {:data, chunk}} ->
        total_bytes = total_bytes + byte_size(chunk)
        total_matches = total_matches + count_newlines(chunk)
        chunks = [chunk | chunks]

        if total_bytes >= grep_max_bytes() or total_matches >= grep_max_matches() do
          # No exit_status will arrive for a port we closed ourselves — that's
          # expected, not an error: report OK + truncated with what we have.
          # Port.close/1 only detaches Erlang from the pipe; git keeps walking
          # the tree until its next stdout write hits SIGPIPE (which can lag
          # arbitrarily), so SIGKILL the OS process directly too. Killing right
          # here, at the moment we decide to stop, means os_pid still names the
          # git process we're abandoning — pid reuse is not a practical race.
          Port.close(port)
          kill_os_pid(os_pid)
          {:ok, complete_records(chunks), true}
        else
          grep_receive(port, os_pid, chunks, total_bytes, total_matches)
        end

      {^port, {:exit_status, status}} ->
        if status in @grep_ok_codes do
          {:ok, complete_records(chunks), false}
        else
          {:error, {:git, status, chunks |> raw_output() |> String.trim()}}
        end
    end
  end

  defp grep_max_bytes,
    do: Application.get_env(:retrieval_node, :grep_max_bytes, @default_grep_max_bytes)

  defp grep_max_matches,
    do: Application.get_env(:retrieval_node, :grep_max_matches, @default_grep_max_matches)

  defp count_newlines(chunk), do: chunk |> :binary.matches("\n") |> length()

  defp raw_output(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  # Drop a trailing partial `<ref>:<path>\0<lineno>\0<text>` record: the budget can
  # cut a chunk mid-record, so only bytes up to (and including) the last complete
  # record's `\n` are safe to hand to parse_grep/3.
  defp complete_records(chunks) do
    raw = raw_output(chunks)

    case :binary.matches(raw, "\n") do
      [] -> ""
      matches -> binary_part(raw, 0, elem(List.last(matches), 0) + 1)
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

  # With `-z`, each record is `<ref>:<path>\0<lineno>\0<text>` (records still \n-
  # separated). NUL field separators mean a `:` anywhere in <path> is safe. Fall
  # through to [] on any record that doesn't parse rather than raising, honoring the
  # "always {:ok, _} | {:error, _}" contract.
  defp parse_grep(slug, ref, out) do
    prefix = ref <> ":"

    out
    |> lines()
    |> Enum.flat_map(fn record ->
      with stripped <- String.replace_prefix(record, prefix, ""),
           [path, line_no, text] <- String.split(stripped, "\0", parts: 3),
           {n, ""} <- Integer.parse(line_no) do
        [%{repo: slug, path: path, line: n, text: text}]
      else
        _ -> []
      end
    end)
  end
end
