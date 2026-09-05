defmodule RetrievalNode.Ingest.ResumeCoordinatorTest do
  use RetrievalNode.DataCase, async: false

  import Ecto.Query

  alias RetrievalNode.Ingest.{PendingChunks, ResumeCoordinator, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

    Application.put_env(
      :retrieval_node,
      :fake_chunk_result,
      {:ok,
       [
         %{
           text: "x",
           breadcrumb: "b",
           start_line: 1,
           end_line: 1,
           kind: "function_definition",
           parse_status: :ok
         }
       ]}
    )

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev)
      Application.delete_env(:retrieval_node, :fake_chunk_result)
    end)

    :ok
  end

  defp seed_source(name) do
    source = Repo.insert!(%Source{source_type: :git_repo, name: name, identifier: "acme/#{name}"})
    on_exit(fn -> SourceOwner.stop(source.id) end)
    source
  end

  defp seed_raw(source, path) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: "repo:#{source.id}:#{path}",
          content_hash: "h-#{System.unique_integer([:positive])}",
          raw_content: "print('#{path}')",
          metadata: %{"path" => path}
        }
      ])
  end

  defp chunk_count(source),
    do: Repo.aggregate(from(c in Chunk, where: c.source_id == ^source.id), :count, :id)

  test "resume/0 drains every source with pending work and returns the count" do
    s1 = seed_source("one")
    s2 = seed_source("two")
    seed_raw(s1, "a.py")
    seed_raw(s2, "b.py")

    assert 2 = ResumeCoordinator.resume()

    assert chunk_count(s1) == 1
    assert chunk_count(s2) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "resume/0 is a no-op (returns 0) when nothing is pending" do
    assert 0 = ResumeCoordinator.resume()
  end

  test "resume/0 honours a configured max_concurrency bound" do
    prev = Application.get_env(:retrieval_node, :resume_max_concurrency)
    Application.put_env(:retrieval_node, :resume_max_concurrency, 1)
    on_exit(fn -> Application.put_env(:retrieval_node, :resume_max_concurrency, prev) end)

    for n <- 1..3 do
      s = seed_source("src#{n}")
      seed_raw(s, "f.py")
    end

    # With max_concurrency 1 the sources drain one at a time; correctness is the
    # observable guarantee (all drained), which also proves the bound doesn't
    # strand any source.
    assert 3 = ResumeCoordinator.resume()
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "resume/0 falls back to the default bound when max_concurrency is misconfigured" do
    prev = Application.get_env(:retrieval_node, :resume_max_concurrency)
    Application.put_env(:retrieval_node, :resume_max_concurrency, 0)
    on_exit(fn -> Application.put_env(:retrieval_node, :resume_max_concurrency, prev) end)

    s = seed_source("cfg")
    seed_raw(s, "f.py")

    # An invalid bound (0) would make Task.async_stream raise — the coordinator
    # must validate it and fall back rather than crash during boot/resume.
    assert 1 = ResumeCoordinator.resume()
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "starting the coordinator process drains pending sources on init (handle_continue)" do
    s = seed_source("boot")
    seed_raw(s, "boot.py")

    {:ok, pid} = start_supervised(ResumeCoordinator)
    # :sys.get_state is handled only AFTER handle_continue(:resume, _) completes,
    # so the synchronous drain is done by the time it returns.
    :sys.get_state(pid)

    assert chunk_count(s) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "resume bounds concurrent drains to max_concurrency" do
    {:ok, _agent} =
      start_supervised(%{
        id: RetrievalNode.Chunking.ResumeConcurrencyProbe,
        start:
          {Agent, :start_link,
           [fn -> %{cur: 0, peak: 0} end, [name: RetrievalNode.Chunking.ResumeConcurrencyProbe]]}
      })

    Application.put_env(
      :retrieval_node,
      :chunking_impl,
      RetrievalNode.Chunking.ResumeConcurrencyProbe
    )

    Application.put_env(:retrieval_node, :resume_max_concurrency, 1)
    on_exit(fn -> Application.delete_env(:retrieval_node, :resume_max_concurrency) end)

    for n <- 1..3 do
      src = seed_source("bound#{n}")
      seed_raw(src, "f.py")
    end

    assert 3 = ResumeCoordinator.resume()

    # With the bound at 1, no two sources ever chunk at the same time. If the
    # bound were ignored/hard-coded higher, the 40ms sleeps would overlap and
    # peak would exceed 1.
    assert %{peak: 1} = Agent.get(RetrievalNode.Chunking.ResumeConcurrencyProbe, & &1)
  end

  test "a :rest_for_one restart re-runs the resume (coordinator is restartable, not :temporary)" do
    # Mirror Ingest.Supervisor's shape: a child BEFORE the coordinator whose
    # death, under :rest_for_one, takes the coordinator down and restarts it —
    # its fresh handle_continue must re-drain work staged since the first run.
    {:ok, sup} =
      Supervisor.start_link(
        [
          %{id: :canary, start: {Agent, :start_link, [fn -> :ok end]}},
          ResumeCoordinator
        ],
        strategy: :rest_for_one
      )

    on_exit(fn -> Process.exit(sup, :normal) end)

    pid1 = Process.whereis(ResumeCoordinator)
    assert is_pid(pid1)

    # Stage work only AFTER the initial (empty) resume, so re-draining it proves
    # the restart re-ran the continuation.
    s = seed_source("recover")
    seed_raw(s, "r.py")

    canary =
      Supervisor.which_children(sup)
      |> Enum.find_value(fn
        {:canary, p, _, _} -> p
        _ -> nil
      end)

    Process.exit(canary, :kill)

    # Wait for the coordinator to be replaced by a new pid, then for its drain.
    wait_for(fn ->
      p = Process.whereis(ResumeCoordinator)
      is_pid(p) and p != pid1
    end)

    :sys.get_state(Process.whereis(ResumeCoordinator))

    assert chunk_count(s) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      tries == 0 -> flunk("condition not met in time")
      fun.() -> :ok
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end
end
