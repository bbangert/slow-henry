defmodule RetrievalNode.Ingest.GitMirrorTest do
  # async: false — mutates the global :git_mirror_root config. Exercises real git
  # against a throwaway local repo (git is always present in dev/CI).
  use ExUnit.Case, async: false

  alias RetrievalNode.Ingest.GitMirror

  setup do
    root = Path.join(System.tmp_dir!(), "gm-test-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:retrieval_node, :git_mirror_root)
    Application.put_env(:retrieval_node, :git_mirror_root, Path.join(root, "mirrors"))

    on_exit(fn ->
      Application.put_env(:retrieval_node, :git_mirror_root, prev)
      File.rm_rf(root)
    end)

    src = Path.join(root, "src")
    File.mkdir_p!(src)
    git!(src, ["init", "-q"])
    git!(src, ["config", "user.email", "t@t"])
    git!(src, ["config", "user.name", "t"])

    File.write!(Path.join(src, "app.py"), "def hello():\n    return 1\n")
    git!(src, ["add", "."])
    git!(src, ["commit", "-qm", "first"])
    sha1 = String.trim(git!(src, ["rev-parse", "HEAD"]))

    File.write!(
      Path.join(src, "app.py"),
      "def hello():\n    return 1\n\ndef bye():\n    return 2\n"
    )

    File.write!(Path.join(src, "LICENSE"), "MIT\n")
    git!(src, ["add", "."])
    git!(src, ["commit", "-qm", "second"])
    sha2 = String.trim(git!(src, ["rev-parse", "HEAD"]))

    {:ok, _} = GitMirror.ensure_mirror("acme/app", "file://" <> src)
    %{sha1: sha1, sha2: sha2, url: "file://" <> src}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  # A repo with `file_count` files of `lines_per_file` matching lines each (well
  # under git grep's own `-m 100` per-file cap when lines_per_file <= 100), padded
  # so the raw `git grep -z -n` output is comfortably larger than a single pipe
  # read — large enough that a tiny grep_max_bytes/grep_max_matches budget is
  # guaranteed to cut mid-stream rather than land on a chunk boundary that already
  # holds everything.
  defp seed_repo_with_many_matches(slug, file_count, lines_per_file) do
    # unique_integer/1 repeats across BEAM runs and this dir used to leak, so a
    # later `mix test` could land on a previous run's repo, write byte-identical
    # files, and fail the commit with "nothing to commit". OS-pid-qualify the
    # path, clear any leftover, and clean up after the test.
    src =
      Path.join(
        System.tmp_dir!(),
        "gm-biggrep-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(src)
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(src) end)
    git!(src, ["init", "-q"])
    git!(src, ["config", "user.email", "t@t"])
    git!(src, ["config", "user.name", "t"])

    line = "needle " <> String.duplicate("x", 100)
    content = String.duplicate(line <> "\n", lines_per_file)

    for i <- 1..file_count do
      File.write!(Path.join(src, "f#{i}.txt"), content)
    end

    git!(src, ["add", "."])
    git!(src, ["commit", "-qm", "many matches"])

    {:ok, _} = GitMirror.ensure_mirror(slug, "file://" <> src)
    :ok
  end

  # W1 fix: grep_receive/5 SIGKILLs the abandoned `git grep` OS process itself
  # (Port.close/1 alone only detaches Erlang — git keeps walking the tree until
  # its next stdout write hits SIGPIPE, which can lag arbitrarily). Confirm no
  # `git grep` process against this mirror survives, polling briefly since the
  # kill is delivered asynchronously (not instant).
  defp assert_git_grep_process_gone(gitdir) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    wait_until_git_grep_process_gone(gitdir, deadline)
  end

  defp wait_until_git_grep_process_gone(gitdir, deadline) do
    if git_grep_process_running?(gitdir) do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(25)
        wait_until_git_grep_process_gone(gitdir, deadline)
      else
        flunk("a git grep process against #{gitdir} is still running 1s after truncation")
      end
    else
      :ok
    end
  end

  defp git_grep_process_running?(gitdir) do
    case System.cmd("pgrep", ["-f", gitdir], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) != []
      _ -> false
    end
  end

  defp assert_well_formed(matches) do
    for m <- matches do
      assert m.repo == "acme/biggrep"
      assert is_binary(m.path) and m.path != ""
      assert is_integer(m.line) and m.line > 0
      assert is_binary(m.text) and m.text =~ "needle"
    end
  end

  test "head_sha resolves HEAD to the latest commit", %{sha2: sha2} do
    assert {:ok, ^sha2} = GitMirror.head_sha("acme/app")
  end

  test "changed_files with nil old_sha lists every file at the ref", %{sha2: sha2} do
    assert {:ok, files} = GitMirror.changed_files("acme/app", nil, sha2)
    assert Enum.sort(files) == ["LICENSE", "app.py"]
  end

  test "changed_files diffs two shas", %{sha1: sha1, sha2: sha2} do
    assert {:ok, files} = GitMirror.changed_files("acme/app", sha1, sha2)
    # app.py changed and LICENSE was added between the two commits.
    assert Enum.sort(files) == ["LICENSE", "app.py"]
  end

  test "show returns a file's exact bytes at HEAD" do
    assert {:ok, "MIT\n"} = GitMirror.show("acme/app", "LICENSE")
  end

  test "show of a missing file returns a git error tuple" do
    assert {:error, {:git, _code, _}} = GitMirror.show("acme/app", "nope.txt")
  end

  test "grep returns {repo, path, line, text} matches, not truncated" do
    assert {:ok, [match], false} = GitMirror.grep("acme/app", "def bye")
    assert match.repo == "acme/app"
    assert match.path == "app.py"
    assert match.text == "def bye():"
    assert is_integer(match.line)
  end

  test "grep with no matches is an empty list, not an error, not truncated" do
    assert {:ok, [], false} = GitMirror.grep("acme/app", "zzz_no_such_token")
  end

  test "grep with an invalid pattern surfaces a git error" do
    assert {:error, {:git, code, _out}} = GitMirror.grep("acme/app", "[")
    assert code not in [0, 1]
  end

  test "ensure_mirror on an existing mirror takes the fetch path (not clone)" do
    # setup already cloned acme/app; a second call must succeed via git fetch.
    assert {:ok, _path} = GitMirror.ensure_mirror("acme/app", "file://irrelevant")
  end

  describe "grep output budgets" do
    setup do
      on_exit(fn ->
        Application.delete_env(:retrieval_node, :grep_max_bytes)
        Application.delete_env(:retrieval_node, :grep_max_matches)
      end)

      seed_repo_with_many_matches("acme/biggrep", 30, 100)
      :ok
    end

    test "a tiny byte budget truncates output without partial-record garbage" do
      Application.put_env(:retrieval_node, :grep_max_bytes, 5_000)
      Application.put_env(:retrieval_node, :grep_max_matches, 1_000_000)

      assert {:ok, matches, true} = GitMirror.grep("acme/biggrep", "needle")
      assert matches != []
      # 30 files × 100 lines = 3000 possible matches; the budget must have cut early.
      assert length(matches) < 3_000
      assert_well_formed(matches)
    end

    test "a tiny byte budget kills the abandoned git grep OS process, not just the port" do
      Application.put_env(:retrieval_node, :grep_max_bytes, 5_000)
      Application.put_env(:retrieval_node, :grep_max_matches, 1_000_000)

      {:ok, gitdir} = GitMirror.mirror_path("acme/biggrep")

      assert {:ok, matches, true} = GitMirror.grep("acme/biggrep", "needle")
      assert matches != []

      assert_git_grep_process_gone(gitdir)
    end

    test "a tiny match budget truncates output without partial-record garbage" do
      Application.put_env(:retrieval_node, :grep_max_matches, 10)
      Application.put_env(:retrieval_node, :grep_max_bytes, 10_000_000)

      assert {:ok, matches, true} = GitMirror.grep("acme/biggrep", "needle")
      assert matches != []
      assert length(matches) < 3_000
      assert_well_formed(matches)
    end

    test "a generous budget returns every match, not truncated" do
      Application.put_env(:retrieval_node, :grep_max_bytes, 10_000_000)
      Application.put_env(:retrieval_node, :grep_max_matches, 1_000_000)

      assert {:ok, matches, false} = GitMirror.grep("acme/biggrep", "needle")
      assert length(matches) == 3_000
      assert_well_formed(matches)
    end
  end

  describe "safety guards" do
    test "show rejects a path-traversal path" do
      assert {:error, :invalid_path} = GitMirror.show("acme/app", "../../../etc/passwd")
    end

    test "mirror_path rejects a traversal repo slug" do
      assert {:error, :invalid_repo} = GitMirror.mirror_path("../evil")
    end

    test "a git-option-injection ref is rejected everywhere (no RCE / file write)" do
      # `--output=…` / `--open-files-in-pager=…` would be a git flag; safe_ref blocks it.
      assert {:error, :invalid_ref} = GitMirror.show("acme/app", "app.py", "--output=/tmp/pwn")

      assert {:error, :invalid_ref} =
               GitMirror.grep("acme/app", "x", "--open-files-in-pager=touch /tmp/pwn")

      assert {:error, :invalid_ref} = GitMirror.head_sha("acme/app", "-abc")
      assert {:error, :invalid_ref} = GitMirror.changed_files("acme/app", nil, "--flag")
      refute File.exists?("/tmp/pwn")
    end

    test "ensure_mirror rejects a non-allowlisted transport (ext:: RCE vector)" do
      assert {:error, :invalid_url} = GitMirror.ensure_mirror("evil", "ext::sh -c whoami")
      assert {:error, :invalid_url} = GitMirror.ensure_mirror("evil", "-oProxyCommand=x")
    end
  end

  describe "timeouts are per-command" do
    test "the short default bounds show/grep but network ops use the longer one", %{url: url} do
      # 0ms = poll once; a freshly-spawned git can't have finished, so any call on
      # the default deterministically times out.
      Application.put_env(:retrieval_node, :git_timeout_ms, 0)
      on_exit(fn -> Application.delete_env(:retrieval_node, :git_timeout_ms) end)

      # show/grep use the (now 1ms) default → they time out.
      assert {:error, :git_timeout} = GitMirror.show("acme/app", "app.py")
      assert {:error, :git_timeout} = GitMirror.grep("acme/app", "hello")

      # fetch (via ensure_mirror on the existing mirror) uses network_timeout, which
      # the 1ms default doesn't touch → it still succeeds.
      assert {:ok, _path} = GitMirror.ensure_mirror("acme/app", url)
    end
  end
end
