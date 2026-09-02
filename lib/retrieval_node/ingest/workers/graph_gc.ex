defmodule RetrievalNode.Ingest.Workers.GraphGc do
  @moduledoc """
  Periodic sweep for graph rows stranded by the ingest pipeline's file-deletion
  paths. Two removal paths exist today, both going through the same
  `Ingest.tombstone_file/4` claim-then-conditionally-delete helper (see
  `RepoSync`'s moduledoc, "Deletion is a tombstone claim"): `RepoSync.delete_removed/2`
  deletes a removed path's `chunks` by `metadata->>"path"`, and
  `DriveSync.delete_removed/2` deletes a removed Doc's `chunks` by
  `metadata->>"doc_id"` (not a filesystem path — Drive files are identified by
  id). `JiraSync` has no removal path today (see `Ingest.file_identity/2`'s
  moduledoc comment). Either deletion's `Repo.delete_all` on `chunks` cascades
  via FK to that file's `entity_mentions`, but leaves behind any `entities`
  (and their `entity_edges`) that now have zero mentions anywhere. Nothing in
  the ingest path itself notices — a deletion event never looks back at the
  entities it just orphaned — so this runs as its own cron job instead.

  An intra-file edit that only shifts chunk boundaries (no path change) used
  to leave the *old* chunk row orphaned forever, with its own graph rows
  (mentions, and any entity that went zero-mention as a result) persisting
  right along with it — `UpsertChunks` now reconciles a file's chunk row set
  on every upsert (deleting rows whose `chunk_key` it no longer produces, see
  its moduledoc), so that gap is closed at the source and this worker no
  longer needs to compensate for it. It remains the catch-all for entities
  that reach zero mentions any other way — this worker only reaps entities
  that are *already* at zero mentions; it has no way to tell a stale chunk
  from a live one, which is fine now that stale chunk rows aren't supposed to
  exist in the first place.
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
