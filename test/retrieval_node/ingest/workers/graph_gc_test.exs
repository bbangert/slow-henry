defmodule RetrievalNode.Ingest.Workers.GraphGcTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # that the application tree starts (same reason as Graph/RepoSync tests).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import ExUnit.CaptureLog

  alias RetrievalNode.Graph.{Entity, EntityMention}
  alias RetrievalNode.Ingest.SourceOwner
  alias RetrievalNode.Ingest.Workers.GraphGc
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  setup do
    # Test env sets Logger level: :warning, which drops :info messages before
    # capture_log ever sees them at all — capture_log's own :level option only
    # narrows, never widens, the global level (and Logger.put_process_level/2
    # doesn't override it either: the global level gate runs before a
    # process-level check gets a say). Bump the global level for the worker's
    # :info GC summary log; async: false on this module plus the on_exit
    # revert keeps the mutation from bleeding into concurrently-running async
    # test files.
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    # perform/1 now runs each source's reap through SourceOwner.gc/1, which
    # starts (or reuses) that source's real owner process under the shared
    # sandbox — stop it so it doesn't linger into the next test.
    on_exit(fn -> SourceOwner.stop(source.id) end)
    %{source: source}
  end

  defp seed_chunk(source, path, chunk_key) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: chunk_key,
      content_hash: "h-#{chunk_key}",
      content: "content",
      context_breadcrumb: path,
      metadata: %{"path" => path}
    })
  end

  defp seed_entity(source, qualified_name) do
    Repo.insert!(%Entity{
      source_id: source.id,
      language: "python",
      qualified_name: qualified_name,
      kind: :function
    })
  end

  test "reaps zero-mention entities and logs the deleted count", %{source: source} do
    chunk = seed_chunk(source, "keep.py", "k1")
    kept = seed_entity(source, "kept")
    Repo.insert!(%EntityMention{entity_id: kept.id, chunk_id: chunk.id, kind: :definition})

    orphan = seed_entity(source, "orphan")

    log = capture_log(fn -> assert :ok = perform_job(GraphGc, %{}) end)

    assert log =~ "graph_gc deleted 1 zero-mention entities"
    refute Repo.get(Entity, orphan.id)
    assert Repo.get(Entity, kept.id)
  end

  test "logs no deleted-count line when there is nothing to reap", %{source: source} do
    chunk = seed_chunk(source, "keep.py", "k1")
    kept = seed_entity(source, "kept")
    Repo.insert!(%EntityMention{entity_id: kept.id, chunk_id: chunk.id, kind: :definition})

    # SourceOwner.gc/1 starts (or reuses) this source's owner, whose own
    # init drain pass always logs a line (Ingest.SourceOwner's per-pass
    # summary) even with nothing to apply — this worker's own "graph_gc
    # deleted N" summary line is what stays conditional on there being
    # something to report.
    log = capture_log(fn -> assert :ok = perform_job(GraphGc, %{}) end)

    refute log =~ "graph_gc deleted"
  end

  test "declares a 30-minute timeout so an unbounded orphan backlog can't squat an :upsert slot forever" do
    assert GraphGc.timeout(%Oban.Job{}) == :timer.minutes(30)
  end
end
