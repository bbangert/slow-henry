defmodule RetrievalNode.Ingest.SourceOwnerTest.PoisonChunker do
  @moduledoc """
  Test-only `Chunking` impl whose `chunk_with_graph/2` fails deterministically
  for content starting with "POISON" and otherwise delegates to the real
  `HeuristicImpl` — lets a test seed both a poison row and healthy rows in the
  same pass without disturbing the rest of the suite's `:fake_chunk_result`-
  driven `FakeImpl`.
  """
  @behaviour RetrievalNode.Chunking

  alias RetrievalNode.Chunking.HeuristicImpl

  @impl true
  def chunk(source, lang), do: HeuristicImpl.chunk(source, lang)

  @impl true
  def allowed_languages, do: []

  @impl true
  def chunk_with_graph("POISON" <> _, _lang), do: {:error, :boom}

  def chunk_with_graph(source, lang) do
    # HeuristicImpl.chunk/2 never returns {:error, _} — no fallback clause
    # needed for that shape here.
    {:ok, chunks} = chunk(source, lang)
    {:ok, %{chunks: chunks, entities: [], references: []}}
  end
end

defmodule RetrievalNode.Ingest.SourceOwnerTest do
  # async: false — shares the SQL sandbox with the SourceOwner GenServers this
  # module starts directly (a separate process, so it needs the shared-sandbox
  # mode DataCase gives `async: false` tests).
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Ingest.{PendingChunks, SourceOwner}
  alias RetrievalNode.Ingest.SourceOwnerTest.PoisonChunker
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    on_exit(fn -> SourceOwner.stop(source.id) end)
    %{source: source}
  end

  defp seed_raw(source, natural_key, path, content, opts \\ []) do
    content_hash =
      Keyword.get(opts, :content_hash, "h-#{System.unique_integer([:positive])}")

    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: natural_key,
          content_hash: content_hash,
          raw_content: content,
          metadata: %{"path" => path},
          force: Keyword.get(opts, :force, false)
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  defp seed_deletion(source, natural_key, path) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          natural_key: natural_key,
          metadata: %{"path" => path},
          status: "deleted"
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  defp chunks_for(source, path) do
    Chunk
    |> where([c], c.source_id == ^source.id)
    |> where([c], fragment("?->>'path'", c.metadata) == ^path)
    |> Repo.all()
  end

  # --- 1. ordering: newest wins, force carries forward -----------------

  test "two queued versions of one file: only the newest is applied", %{source: source} do
    seed_raw(source, "repo:x:a.py", "a.py", "v1\n")
    seed_raw(source, "repo:x:a.py", "a.py", "v2\n")

    assert {:ok, stats} = SourceOwner.drain(source.id)
    assert stats.applied == 1
    assert stats.superseded == 1

    assert [chunk] = chunks_for(source, "a.py")
    assert chunk.content =~ "v2"
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "a superseded row's force: true carries forward onto the kept row", %{source: source} do
    seed_raw(source, "repo:x:c.py", "c.py", "same content\n", content_hash: "stable-hash")
    assert {:ok, stats0} = SourceOwner.drain(source.id)
    assert stats0.applied == 1

    seed_raw(source, "repo:x:c.py", "c.py", "same content\n",
      content_hash: "stable-hash",
      force: true
    )

    seed_raw(source, "repo:x:c.py", "c.py", "same content\n", content_hash: "stable-hash")

    assert {:ok, stats} = SourceOwner.drain(source.id)
    assert stats.superseded == 1
    # force propagated from the superseded row: this re-applied instead of
    # taking the unchanged-content skip an unforced apply would have hit.
    # `drain/1`'s stats are cumulative since the owner started: 1 from the
    # first drain above + 1 from this pass.
    assert stats.applied == 2
    assert stats.skipped == 0
  end

  # --- 2. deletion / re-add ordering ------------------------------------

  test "deletion after content removes chunks; content after deletion re-indexes", %{
    source: source
  } do
    seed_raw(source, "repo:x:d.py", "d.py", "hello\n")
    assert {:ok, stats0} = SourceOwner.drain(source.id)
    assert stats0.applied == 1
    assert length(chunks_for(source, "d.py")) == 1

    # `drain/1`'s stats are cumulative since the owner started, so each
    # further call's `applied` keeps growing on top of stats0's.
    seed_deletion(source, "repo:x:d.py", "d.py")
    assert {:ok, stats1} = SourceOwner.drain(source.id)
    assert stats1.applied == 2
    assert chunks_for(source, "d.py") == []

    seed_raw(source, "repo:x:d.py", "d.py", "hello again\n")
    assert {:ok, stats2} = SourceOwner.drain(source.id)
    assert stats2.applied == 3
    assert [chunk] = chunks_for(source, "d.py")
    assert chunk.content =~ "hello again"
  end

  # --- 3. poison rows ----------------------------------------------------

  describe "poison rows" do
    setup do
      prev = Application.get_env(:retrieval_node, :chunking_impl)
      Application.put_env(:retrieval_node, :chunking_impl, PoisonChunker)
      on_exit(fn -> Application.put_env(:retrieval_node, :chunking_impl, prev) end)
      :ok
    end

    test "a poison row is marked and skipped; the rest of the queue still drains", %{
      source: source
    } do
      poison = seed_raw(source, "repo:x:bad.py", "bad.py", "POISON content\n")
      seed_raw(source, "repo:x:good.py", "good.py", "fine content\n")

      assert {:ok, stats} = SourceOwner.drain(source.id)
      assert stats.applied == 1
      assert stats.failed == 1

      assert chunks_for(source, "good.py") != []
      assert chunks_for(source, "bad.py") == []

      marked = PendingChunks.fetch!(poison.id)
      assert marked.attempts == 1
      assert marked.last_error =~ "boom"
      assert DateTime.compare(marked.retry_after, DateTime.utc_now()) == :gt
    end

    test "after max_file_attempts marks, the row is excluded from drainable/2 and counted by failed_count/0",
         %{source: source} do
      poison = seed_raw(source, "repo:x:bad2.py", "bad2.py", "POISON content\n")

      Repo.update_all(from(p in PendingChunk, where: p.id == ^poison.id),
        set: [attempts: SourceOwner.max_file_attempts()]
      )

      assert PendingChunks.drainable(source.id) == []
      assert PendingChunks.failed_count() == 1
    end
  end

  # --- 4. crash + restart --------------------------------------------------

  test "owner crash mid-drain: restart re-applies without duplicates", %{source: source} do
    {:ok, pid1} =
      DynamicSupervisor.start_child(
        RetrievalNode.Ingest.SourceSupervisor,
        SourceOwner.child_spec(source.id)
      )

    seed_raw(source, "repo:x:e.py", "e.py", "hello\n")
    seed_raw(source, "repo:x:f.py", "f.py", "world\n")

    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}

    assert {:ok, _stats} = SourceOwner.drain(source.id)

    new_pid = SourceOwner.whereis(source.id)
    assert is_pid(new_pid)
    assert new_pid != pid1

    assert length(chunks_for(source, "e.py")) == 1
    assert length(chunks_for(source, "f.py")) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  # --- 5. concurrent notifies coalesce -------------------------------------

  describe "notify/1 coalescing" do
    setup do
      prev = Application.get_env(:retrieval_node, :source_owner_notify)
      Application.put_env(:retrieval_node, :source_owner_notify, true)
      on_exit(fn -> Application.put_env(:retrieval_node, :source_owner_notify, prev) end)
      :ok
    end

    test "5 concurrent notifies for the same source coalesce — every row applied once", %{
      source: source
    } do
      for n <- 1..5, do: seed_raw(source, "repo:x:file#{n}.py", "file#{n}.py", "content #{n}\n")

      1..5
      |> Enum.map(fn _ -> Task.async(fn -> SourceOwner.notify(source.id) end) end)
      |> Enum.each(&Task.await/1)

      assert {:ok, _stats} = SourceOwner.drain(source.id)

      assert is_pid(SourceOwner.whereis(source.id))

      for n <- 1..5 do
        assert length(chunks_for(source, "file#{n}.py")) == 1
      end

      assert Repo.aggregate(PendingChunk, :count, :id) == 0
    end
  end

  # --- 6. idle stop + restart -----------------------------------------------

  test "idle timeout stops the owner; a later drain starts a fresh one", %{source: source} do
    seed_raw(source, "repo:x:g.py", "g.py", "content\n")
    assert {:ok, _} = SourceOwner.drain(source.id)

    pid = SourceOwner.whereis(source.id)
    assert is_pid(pid)

    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    refute SourceOwner.whereis(source.id)

    seed_raw(source, "repo:x:h.py", "h.py", "more content\n")
    assert {:ok, _} = SourceOwner.drain(source.id)

    new_pid = SourceOwner.whereis(source.id)
    assert is_pid(new_pid)
    assert new_pid != pid
    assert length(chunks_for(source, "h.py")) == 1
  end

  # --- 8. resume_all/0 ------------------------------------------------------

  describe "resume_all/0" do
    setup do
      prev = Application.get_env(:retrieval_node, :source_owner_notify)
      Application.put_env(:retrieval_node, :source_owner_notify, true)
      on_exit(fn -> Application.put_env(:retrieval_node, :source_owner_notify, prev) end)
      :ok
    end

    test "notifies every source that has at least one drainable row", %{source: source} do
      other_source =
        Repo.insert!(%Source{source_type: :git_repo, name: "other", identifier: "acme/other"})

      on_exit(fn -> SourceOwner.stop(other_source.id) end)

      seed_raw(source, "repo:x:i.py", "i.py", "hi\n")
      seed_raw(other_source, "repo:y:j.py", "j.py", "hey\n")

      assert :ok = SourceOwner.resume_all()

      assert is_pid(SourceOwner.whereis(source.id))
      assert is_pid(SourceOwner.whereis(other_source.id))

      assert {:ok, _} = SourceOwner.drain(source.id)
      assert {:ok, _} = SourceOwner.drain(other_source.id)

      assert length(chunks_for(source, "i.py")) == 1
      assert length(chunks_for(other_source, "j.py")) == 1
    end
  end

  # --- 9. :timeout with drainable rows drains instead of stopping ----------

  test "handle_info(:timeout) with drainable rows drains instead of stopping", %{source: source} do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        RetrievalNode.Ingest.SourceSupervisor,
        SourceOwner.child_spec(source.id)
      )

    # Ensure the owner's initial (empty-queue) continue-triggered pass has
    # already completed before seeding — otherwise that pass could race
    # ahead and consume the row below before the manual :timeout ever gets
    # processed, defeating the scenario this test exercises.
    assert {:ok, _stats} = GenServer.call(pid, :drain, :infinity)

    seed_raw(source, "repo:x:k.py", "k.py", "content\n")

    send(pid, :timeout)

    assert {:ok, _stats} = GenServer.call(pid, :drain, :infinity)
    assert Process.alive?(pid)
    assert length(chunks_for(source, "k.py")) == 1
  end
end
