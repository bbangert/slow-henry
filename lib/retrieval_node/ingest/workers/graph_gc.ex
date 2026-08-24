defmodule RetrievalNode.Ingest.Workers.GraphGc do
  @moduledoc """
  Periodic sweep for graph rows stranded by the ingest pipeline's file-deletion
  path: `RepoSync.delete_removed/2` (and the analogous `DriveSync`/`JiraSync`
  paths) run a path-based `Repo.delete_all` on `chunks`, whose FK cascade kills
  that file's `entity_mentions` but leaves behind any `entities` (and their
  `entity_edges`) that now have zero mentions anywhere. Nothing in the ingest
  path itself notices — a deletion event never looks back at the entities it
  just orphaned — so this runs as its own cron job instead.

  Documented gap this does NOT cover: an intra-file edit that only shifts
  chunk boundaries (no path change) can leave the *old* chunk row orphaned
  (pre-existing pipeline gap, not fixed here) — that orphaned chunk's own
  graph rows (its mentions, and any entity that becomes zero-mention as a
  result) persist right along with it. This worker only reaps entities that
  are *already* at zero mentions; it has no way to tell a stale chunk from a
  live one.
  """
  use Oban.Worker,
    queue: :upsert,
    max_attempts: 3,
    unique: [
      period: {1, :hour},
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias RetrievalNode.Graph

  # An unbounded orphan backlog (plausible post-backfill or after a large
  # repo deletion) must not squat an :upsert slot indefinitely, competing
  # with latency-sensitive UpsertChunks jobs. Graph.gc_orphaned_entities/1's
  # batched loop makes a timeout-triggered retry resume roughly where it left
  # off — already-deleted batches don't come back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Graph.gc_orphaned_entities() do
      0 ->
        :ok

      deleted ->
        Logger.info("graph_gc deleted #{deleted} zero-mention entities")
        :ok
    end
  end
end
