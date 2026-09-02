defmodule RetrievalNode.Ingest.Workers.RepoSyncTest do
  # async: false — mutates :git_mirror_root; shares the SQL sandbox with the
  # (manual-mode) Oban instance the application tree starts; real git.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import ExUnit.CaptureLog

  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.Workers.{ChunkFiles, EmbedBatch, RepoSync, UpsertChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, FileVersion, PendingChunk, Source, SyncState}

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

  test "first sync ingests every file, enqueues ChunkFiles, advances the watermark", ctx do
    commit(ctx.src, [{"a.py", "def a(): pass\n"}, {"b.py", "def b(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")

    assert Enum.sort(Enum.map(raws, & &1.natural_key)) ==
             ["repo:#{ctx.source.id}:a.py", "repo:#{ctx.source.id}:b.py"]

    assert Enum.all?(raws, &(&1.lang == "python" and &1.source_id == ctx.source.id))
    assert_enqueued(worker: ChunkFiles)

    # watermark advanced to HEAD
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

  test "a deleted file removes its permanent chunks and leaves file_versions as a tombstone with a higher generation",
       ctx do
    commit(ctx.src, [{"gone.py", "def g(): pass\n"}])
    perform_job(RepoSync, %{"source_id" => ctx.source.id})

    # Simulate the chunk already having been upserted for gone.py.
    Repo.insert!(%Chunk{
      source_id: ctx.source.id,
      source_type: :git_repo,
      chunk_key: "k1",
      content_hash: "h",
      content: "def g(): pass",
      context_breadcrumb: "gone.py",
      metadata: %{"path" => "gone.py"}
    })

    # Simulate a version already having been claimed for gone.py too.
    Repo.insert!(%FileVersion{source_id: ctx.source.id, identity: "gone.py", generation: 1})

    File.rm!(Path.join(ctx.src, "gone.py"))
    File.write!(Path.join(ctx.src, "keep.py"), "def k(): pass\n")
    git!(ctx.src, ["add", "-A"])
    git!(ctx.src, ["commit", "-qm", "rm"])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "k1"), :count, :id) == 0

    # The file_versions row is NEVER deleted — deletion is a tombstone claim,
    # not a guard-row delete (see the moduledoc). The claimed generation is
    # strictly greater than the prior one.
    tombstone = Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "gone.py")
    assert tombstone.generation > 1
  end

  describe "delete_removed/2 tombstone claim (Fix 1)" do
    test "THE HOLE: a delayed pre-deletion UpsertChunks job is stale, not a resurrection", ctx do
      commit(ctx.src, [{"hole.py", "def h(): pass\n"}])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

      # v1's raw row is staged and ChunkFiles enqueued, but NOT yet run — an
      # hours-deep backlog stalls it right here.
      raw1 = Repo.one!(from p in PendingChunk, where: p.status == "raw")

      # The path is deleted and re-synced BEFORE v1's pipeline ever runs.
      File.rm!(Path.join(ctx.src, "hole.py"))
      git!(ctx.src, ["add", "-A"])
      git!(ctx.src, ["commit", "-qm", "rm"])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

      # The tombstone claim landed for hole.py, at a generation greater than
      # raw1's id (same pending_chunks id sequence the deletion drew from).
      tombstone = Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "hole.py")
      assert tombstone.generation > raw1.id

      # v1's stalled pipeline finally runs to completion.
      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw1.id})
      ids = Repo.all(from p in PendingChunk, select: p.id)
      assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
      ids = Repo.all(from p in PendingChunk, where: p.id in ^ids, select: p.id)
      assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})

      # No chunk was resurrected for hole.py, and staging is fully drained —
      # the stale claim still cleans up its own staging rows.
      assert Repo.aggregate(from(c in Chunk, where: c.source_id == ^ctx.source.id), :count, :id) ==
               0

      assert Repo.aggregate(PendingChunk, :count, :id) == 0

      # The tombstone's generation is untouched by the stale claim.
      assert Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "hole.py").generation ==
               tombstone.generation
    end

    test "a re-added file after a deletion claims a higher generation and persists normally",
         ctx do
      commit(ctx.src, [{"back.py", "def b(): return 1\n"}])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
      raw1 = Repo.one!(from p in PendingChunk, where: p.status == "raw")
      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw1.id})
      ids = Repo.all(from p in PendingChunk, select: p.id)
      assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
      ids = Repo.all(from p in PendingChunk, where: p.id in ^ids, select: p.id)
      assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})
      assert [_] = Repo.all(from c in Chunk, where: c.source_id == ^ctx.source.id)

      # Delete it — tombstone claim removes the chunk.
      File.rm!(Path.join(ctx.src, "back.py"))
      git!(ctx.src, ["add", "-A"])
      git!(ctx.src, ["commit", "-qm", "rm"])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
      assert Repo.all(from c in Chunk, where: c.source_id == ^ctx.source.id) == []

      tombstone = Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "back.py")

      # Re-add the file with new content — a fresh raw row, at a higher id
      # than the tombstone's claimed generation.
      commit(ctx.src, [{"back.py", "def b(): return 2\n"}])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
      raw2 = Repo.one!(from p in PendingChunk, where: p.status == "raw")
      assert raw2.id > tombstone.generation

      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw2.id})
      ids2 = Repo.all(from p in PendingChunk, select: p.id)
      assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids2})
      ids2 = Repo.all(from p in PendingChunk, where: p.id in ^ids2, select: p.id)
      assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids2})

      assert [chunk] = Repo.all(from c in Chunk, where: c.source_id == ^ctx.source.id)
      assert chunk.content =~ "return 2"

      assert Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "back.py").generation ==
               raw2.id
    end

    test "a deletion that loses to an already-higher committed generation leaves that version's chunks untouched",
         ctx do
      commit(ctx.src, [{"newer.py", "def n(): pass\n"}])
      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

      # Simulate a newer version of newer.py that already committed at a
      # generation higher than anything this deletion's tombstone draw could
      # produce (the sequence's current value is nowhere near this).
      future_generation = Ingest.next_ingest_generation(Repo) + 1_000_000

      Repo.insert!(%Chunk{
        source_id: ctx.source.id,
        source_type: :git_repo,
        chunk_key: "future-k1",
        content_hash: "h",
        content: "def n(): pass  # newer",
        context_breadcrumb: "newer.py",
        metadata: %{"path" => "newer.py"},
        ingest_generation: future_generation
      })

      Repo.insert!(%FileVersion{
        source_id: ctx.source.id,
        identity: "newer.py",
        generation: future_generation
      })

      File.rm!(Path.join(ctx.src, "newer.py"))
      git!(ctx.src, ["add", "-A"])
      git!(ctx.src, ["commit", "-qm", "rm"])

      assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

      # The deletion's claim lost (:stale) — the newer chunk is untouched and
      # the tombstone's generation is unchanged.
      assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "future-k1"), :count, :id) == 1

      assert Repo.get_by!(FileVersion, source_id: ctx.source.id, identity: "newer.py").generation ==
               future_generation
    end
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
    # upserted by the pipeline), and a fresh raw row is staged for re-chunking
    assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "mk1"), :count, :id) == 1
    raw = Repo.one!(from p in PendingChunk, where: p.status == "raw")
    assert raw.natural_key == "repo:#{ctx.source.id}:mod.py"
    assert raw.raw_content =~ "return 42"
    assert_enqueued(worker: ChunkFiles)
  end

  test "a repo with a binary file skips it — text file still staged, job still completes", ctx do
    # Reproduces the real bug: a tracked binary (e.g. favicon.ico) must not crash
    # the whole sync job by way of an invalid-UTF-8 insert into the text column.
    File.write!(Path.join(ctx.src, "favicon.ico"), <<0, 255, 216, 0>>)
    commit(ctx.src, [{"app.py", "def a(): pass\n"}])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})

    raws = Repo.all(from p in PendingChunk, where: p.status == "raw")
    assert Enum.map(raws, & &1.natural_key) == ["repo:#{ctx.source.id}:app.py"]
    assert_enqueued(worker: ChunkFiles)

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
    assert_enqueued(worker: ChunkFiles)
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
    assert_enqueued(worker: ChunkFiles)

    # no staged row (and no ChunkFiles job) for the gitlink path
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
    refute_enqueued(worker: ChunkFiles)

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

  describe "advance_watermark/2 optimistic write" do
    test "advances when the DB row's cursor still matches what was read at job start", ctx do
      state =
        Repo.insert!(%SyncState{
          source_id: ctx.source.id,
          cursor: %{"last_sha" => "old-sha"},
          status: :syncing
        })

      assert :ok = RepoSync.advance_watermark(state, "new-sha")

      updated = Repo.get_by!(SyncState, source_id: ctx.source.id)
      assert updated.cursor == %{"last_sha" => "new-sha"}
      assert updated.status == :idle
    end

    test "does NOT advance when the DB row's cursor changed since it was read (concurrent clear/backfill)",
         ctx do
      state =
        Repo.insert!(%SyncState{
          source_id: ctx.source.id,
          cursor: %{"last_sha" => "old-sha"},
          status: :syncing
        })

      # Simulate Ingest.force_full_resync_git_sources/0's clear_sync_cursor!/1
      # racing in after `state` was read (at perform/1 start) but before
      # advance_watermark runs.
      state |> SyncState.changeset(%{cursor: %{}}) |> Repo.update!()

      log =
        capture_log(fn ->
          assert :ok = RepoSync.advance_watermark(state, "new-sha")
        end)

      assert log =~ "not advancing watermark"

      # cursor stays at the CONCURRENTLY-CLEARED value — the stale `state`
      # struct's computed new_sha must never overwrite it.
      updated = Repo.get_by!(SyncState, source_id: ctx.source.id)
      assert updated.cursor == %{}
    end
  end
end
