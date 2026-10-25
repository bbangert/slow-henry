defmodule RetrievalNode.Ingest.Workers.GraphGc do
  @moduledoc """
  Daily per-source sweep for zero-mention entities. REQUIRED, not a belt-and-
  braces extra: `Ingest.SourceOwner` only reaps orphans after a pass that
  removes chunks (reconcile/delete), so an in-place update that drops a call
  target leaves its entity with zero mentions and nothing reaps it until this
  sweep runs. It also catches orphans from before graph extraction existed.

  Fans out per source rather than running one corpus-wide sweep: distinct
  `source_id`s with at least one `entities` row, `Ingest.SourceOwner.gc/1`
  each in turn (sequential, synchronous — this worker is a slow daily cron
  job, not a latency-sensitive path, so there's no reason to run sources
  concurrently). `SourceOwner.gc/1` runs `Graph.gc_orphaned_entities/1`
  scoped to that source INSIDE the owning process's mailbox — the same
  single-writer guarantee every other write to that source's graph rows
  goes through, so this sweep never races a sync landing new mentions for a
  source it's currently scanning.

  `queue: :sync` — the one queue present in every env (discovery workers run
  there too).
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
  #
  # Must stay BELOW Oban.Plugins.Lifeline's `rescue_after` (config.exs, 20
  # minutes): Lifeline rescues by elapsed execution time, so a longer timeout
  # would let it re-run a sweep that is still executing (enforced by a test).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

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
