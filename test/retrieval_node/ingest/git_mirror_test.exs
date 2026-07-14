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

  test "grep returns {repo, path, line, text} matches" do
    assert {:ok, [match]} = GitMirror.grep("acme/app", "def bye")
    assert match.repo == "acme/app"
    assert match.path == "app.py"
    assert match.text == "def bye():"
    assert is_integer(match.line)
  end

  test "grep with no matches is an empty list, not an error" do
    assert {:ok, []} = GitMirror.grep("acme/app", "zzz_no_such_token")
  end

  test "ensure_mirror on an existing mirror takes the fetch path (not clone)" do
    # setup already cloned acme/app; a second call must succeed via git fetch.
    assert {:ok, _path} = GitMirror.ensure_mirror("acme/app", "file://irrelevant")
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
