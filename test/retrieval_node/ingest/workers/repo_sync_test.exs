defmodule RetrievalNode.Ingest.Workers.RepoSyncTest do
  # async: false — mutates :git_mirror_root; shares the SQL sandbox with the
  # (manual-mode) Oban instance the application tree starts; real git.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  setup do
    root = Path.join(System.tmp_dir!(), "reposync-#{System.unique_integer([:positive])}")
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

    source =
      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "acme/app",
        identifier: "file://" <> src,
        config: %{}
      })

    %{src: src, source: source}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp commit(src, files) do
    Enum.each(files, fn {path, content} -> File.write!(Path.join(src, path), content) end)
    git!(src, ["add", "-A"])
    git!(src, ["commit", "-qm", "c"])
  end

  test "first sync stages a raw row per file, advances the watermark",
       ctx do
    commit(ctx.src, [{"a.py", "def a(): pass\n"}, {"b.py", "def b(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")

    assert Enum.sort(Enum.map(raws, & &1.natural_key)) ==
             ["repo:#{ctx.source.id}:a.py", "repo:#{ctx.source.id}:b.py"]

    assert Enum.all?(raws, &(&1.lang == "python" and &1.source_id == ctx.source.id))
    assert Enum.all?(raws, &(&1.force == false))

    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end

  test ".ex and .exs files are tagged lang: \"elixir\"", ctx do
    commit(ctx.src, [
      {"a.ex", "defmodule A do\nend\n"},
      {"a_test.exs", "1 + 1\n"}
    ])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")

    assert Enum.sort(Enum.map(raws, & &1.natural_key)) ==
             ["repo:#{ctx.source.id}:a.ex", "repo:#{ctx.source.id}:a_test.exs"]

    assert Enum.all?(raws, &(&1.lang == "elixir"))
  end

  test "an unchanged repo is a no-op on the second sync", ctx do
    commit(ctx.src, [{"a.py", "x\n"}])
    perform_job(RepoSync, %{"source_id" => ctx.source.id})
    Repo.delete_all(PendingChunk)

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "a deleted file stages a deletion entry — chunks are untouched here, that's the owner's job",
       ctx do
    commit(ctx.src, [{"gone.py", "def g(): pass\n"}])
    perform_job(RepoSync, %{"source_id" => ctx.source.id})
    Repo.delete_all(PendingChunk)

    # Simulate the chunk already having been indexed for gone.py by an owner.
    Repo.insert!(%Chunk{
      source_id: ctx.source.id,
      source_type: :git_repo,
      chunk_key: "k1",
      content_hash: "h",
      content: "def g(): pass",
      context_breadcrumb: "gone.py",
      metadata: %{"path" => "gone.py"}
    })

    File.rm!(Path.join(ctx.src, "gone.py"))
    File.write!(Path.join(ctx.src, "keep.py"), "def k(): pass\n")
    git!(ctx.src, ["add", "-A"])
    git!(ctx.src, ["commit", "-qm", "rm"])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    # RepoSync only appends to the mailbox — it never deletes a chunks row
    # itself (Ingest.SourceOwner does, when it applies this entry).
    assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "k1"), :count, :id) == 1

    deletion =
      Repo.one!(from p in PendingChunk, where: p.natural_key == ^"repo:#{ctx.source.id}:gone.py")

    assert deletion.status == "deleted"
    assert deletion.metadata == %{"path" => "gone.py"}

    added =
      Repo.one!(from p in PendingChunk, where: p.natural_key == ^"repo:#{ctx.source.id}:keep.py")

    assert added.status == "raw"

    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end

  test "a modified file is re-enqueued, NOT treated as a deletion", ctx do
    commit(ctx.src, [{"mod.py", "def m(): pass\n"}])
    perform_job(RepoSync, %{"source_id" => ctx.source.id})

    # a permanent chunk already exists for mod.py
    Repo.insert!(%Chunk{
      source_id: ctx.source.id,
      source_type: :git_repo,
      chunk_key: "mk1",
      content_hash: "h",
      content: "def m(): pass",
      context_breadcrumb: "mod.py",
      metadata: %{"path" => "mod.py"}
    })

    Repo.delete_all(PendingChunk)
    commit(ctx.src, [{"mod.py", "def m(): return 42\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    # modification is NOT a deletion — the existing chunk survives (it'll be
    # upserted by the owner), and a fresh raw row is staged for re-chunking
    assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "mk1"), :count, :id) == 1
    raw = Repo.one!(from p in PendingChunk, where: p.status == "raw")
    assert raw.natural_key == "repo:#{ctx.source.id}:mod.py"
    assert raw.raw_content =~ "return 42"
  end

  test "\"full\" => true ignores the cursor and stages every file with force: true", ctx do
    commit(ctx.src, [{"a.py", "def a(): pass\n"}])
    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    Repo.delete_all(PendingChunk)

    commit(ctx.src, [{"b.py", "def b(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id, "full" => true})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")

    # both files staged — a.py too, even though it was already synced and
    # the second commit alone would have only diffed b.py.
    assert Enum.sort(Enum.map(raws, & &1.natural_key)) ==
             ["repo:#{ctx.source.id}:a.py", "repo:#{ctx.source.id}:b.py"]

    assert Enum.all?(raws, &(&1.force == true))

    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end

  test "a repo with a binary file skips it — text file still staged, job still completes", ctx do
    # Reproduces the real bug: a tracked binary (e.g. favicon.ico) must not crash
    # the whole sync job by way of an invalid-UTF-8 insert into the text column.
    File.write!(Path.join(ctx.src, "favicon.ico"), <<0, 255, 216, 0>>)
    commit(ctx.src, [{"app.py", "def a(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")
    assert Enum.map(raws, & &1.natural_key) == ["repo:#{ctx.source.id}:app.py"]

    # watermark still advances past the binary file — it isn't retried forever
    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end

  test "a repo with invalid-UTF-8-but-no-NUL content skips that file too", ctx do
    File.write!(Path.join(ctx.src, "mystery.bin"), <<255, 254>> <> "not valid utf8")
    commit(ctx.src, [{"app.py", "def a(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")
    assert Enum.map(raws, & &1.natural_key) == ["repo:#{ctx.source.id}:app.py"]
  end

  test "a repo with a submodule syncs the real files and skips the gitlink entirely", ctx do
    sub = Path.join(System.tmp_dir!(), "reposync-sub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sub)
    on_exit(fn -> File.rm_rf(sub) end)
    git!(sub, ["init", "-q"])
    git!(sub, ["config", "user.email", "t@t"])
    git!(sub, ["config", "user.name", "t"])
    File.write!(Path.join(sub, "f.txt"), "hi\n")
    git!(sub, ["add", "."])
    git!(sub, ["commit", "-qm", "sub"])
    sub_sha = String.trim(git!(sub, ["rev-parse", "HEAD"]))

    commit(ctx.src, [{"app.py", "def a(): pass\n"}])
    git!(ctx.src, ["update-index", "--add", "--cacheinfo", "160000,#{sub_sha},sublib"])
    git!(ctx.src, ["commit", "-qm", "add submodule"])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")
    assert Enum.map(raws, & &1.natural_key) == ["repo:#{ctx.source.id}:app.py"]

    # no staged row for the gitlink path
    refute Repo.get_by(PendingChunk, natural_key: "repo:#{ctx.source.id}:sublib")

    # job completed (didn't retry-forever the way a job-fatal submodule would),
    # and the watermark advanced past the submodule commit
    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end

  test "an empty repo (no commits) completes as a no-op — no rows, no watermark", ctx do
    # ctx.src was git-init'd by setup but nothing was ever committed to it.
    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    assert Repo.aggregate(from(p in PendingChunk), :count, :id) == 0

    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor == %{}
    assert is_nil(Map.get(state.cursor, "last_sha"))
  end

  test "a repo that starts empty and later gains commits syncs normally on the next tick", ctx do
    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor == %{}

    commit(ctx.src, [{"a.py", "def a(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")
    assert Enum.map(raws, & &1.natural_key) == ["repo:#{ctx.source.id}:a.py"]

    head = String.trim(git!(ctx.src, ["rev-parse", "HEAD"]))
    state = Repo.get_by!(SyncState, source_id: ctx.source.id)
    assert state.cursor["last_sha"] == head
  end
end
