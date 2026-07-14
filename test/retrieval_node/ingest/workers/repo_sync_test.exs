defmodule RetrievalNode.Ingest.Workers.RepoSyncTest do
  # async: false — starts Oban (manual) + mutates :git_mirror_root; real git.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.{ChunkFiles, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  setup do
    start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})

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

  test "an unchanged repo is a no-op on the second sync", ctx do
    commit(ctx.src, [{"a.py", "x\n"}])
    perform_job(RepoSync, %{"source_id" => ctx.source.id})
    Repo.delete_all(PendingChunk)

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "a deleted file removes its permanent chunks on the next sync", ctx do
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

    File.rm!(Path.join(ctx.src, "gone.py"))
    File.write!(Path.join(ctx.src, "keep.py"), "def k(): pass\n")
    git!(ctx.src, ["add", "-A"])
    git!(ctx.src, ["commit", "-qm", "rm"])

    assert :ok = perform_job(RepoSync, %{"source_id" => ctx.source.id})
    assert Repo.aggregate(from(c in Chunk, where: c.chunk_key == "k1"), :count, :id) == 0
  end
end
