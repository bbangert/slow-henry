defmodule RetrievalNode.Ingest.Workers.GraphGc do
  @moduledoc """
  Daily catch-all sweep for zero-mention entities. `Ingest.SourceOwner`
  already reaps its own source's orphans after every pass that reconciles or
  deletes a file (see its moduledoc's "one pass" step 4) — this worker exists
  for whatever that doesn't catch: orphans from before that behavior existed,
  or from any path that touches `chunks` outside an owner's pass.

  Fans out per source rather than running one corpus-wide sweep: distinct
  `source_id`s with at least one `entities` row, `Ingest.SourceOwner.gc/1`
  each in turn (sequential, synchronous — this worker is a slow daily cron
  job, not a latency-sensitive path, so there's no reason to run sources
  concurrently). `SourceOwner.gc/1` runs `Graph.gc_orphaned_entities/1`
  scoped to that source INSIDE the owning process's mailbox — the same
  single-writer guarantee every other write to that source's graph rows
  goes through, so this sweep never races a sync landing new mentions for a
  source it's currently scanning.

  `queue: :sync` — the old per-file staging pipeline's own upsert queue is
  gone along with it; `:sync` is the one queue that exists in every env
  already (discovery workers run there too).
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [
      period: {1, :hour},
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  require Logger

  alias RetrievalNode.Graph.Entity
  alias RetrievalNode.Ingest.SourceOwner
  alias RetrievalNode.Repo

  # An unbounded orphan backlog (plausible post-backfill or after a large
  # repo deletion) must not squat a :sync slot indefinitely, competing with
  # discovery jobs. Each source's own gc_orphaned_entities/1 call is itself
  # a batched loop, so a timeout-triggered retry resumes roughly where the
  # sweep left off — sources already fully reaped don't come back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    total =
      source_ids_with_entities()
      |> Enum.reduce(0, fn source_id, total ->
        {:ok, deleted} = SourceOwner.gc(source_id)
        total + deleted
      end)

    if total > 0 do
      Logger.info("graph_gc deleted #{total} zero-mention entities")
    end

    :ok
  end

  defp source_ids_with_entities do
    Entity |> distinct(true) |> select([e], e.source_id) |> Repo.all()
  end
end
