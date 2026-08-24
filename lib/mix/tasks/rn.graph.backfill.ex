defmodule Mix.Tasks.Rn.Graph.Backfill do
  @shortdoc "Forces a full re-sync of every active git source to backfill graph extraction"

  @moduledoc """
  Forces a full re-sync of every active git source through the existing
  4-stage ingest pipeline (`RepoSync` -> `ChunkFiles` -> `EmbedBatch` ->
  `UpsertChunks`), so newly-added graph extraction (entities/entity_mentions/
  entity_edges) backfills onto the whole corpus — not just files touched by
  future syncs.

  ## Mechanism

  Clears each git source's sync watermark (`sync_states.cursor`'s
  `"last_sha"`) and enqueues a `RepoSync` job for it. `RepoSync` with no
  `last_sha` diffs against nothing and stages every file in the repo (see its
  moduledoc), so every chunk flows back through `ChunkFiles`, which now
  extracts entities/mentions per chunk.

  ## Idempotency

  This is a replace, not a duplicate: `ChunkFiles`/`UpsertChunks` key each
  chunk on `chunk_key`/`content_hash`, so re-processing unchanged content
  upserts the same row. `RepoSync`'s 15-minute `unique` window on `source_id`
  means an overlapping cron-driven sync for the same source dedups onto one
  job — harmless here, since the cursor is cleared before either job runs, so
  whichever one actually executes does the full re-stage.

  ## This is expensive — deliberately

  At ~586k chunks corpus-wide, this re-embeds the *entire* corpus through
  `EmbedBatch` again, not just newly-extracted graph data. Expect this to run
  for **hours**. That's an accepted tradeoff of this task's plan (piggyback
  on the existing pipeline's idempotency instead of writing a graph-only
  extraction path) — not an oversight.

  ## Where the work actually happens

  This task only enqueues jobs — see "Boot" below, it deliberately runs no
  queues of its own. The enqueued `RepoSync`/`ChunkFiles`/`EmbedBatch`/
  `UpsertChunks` jobs execute on whatever node is actually running Oban
  queues (the dev server, or the production Oban instance), NOT this admin
  task's process. That other process must already be up (or come up) for
  the backfill to make progress; watch it with `mix rn.graph.backfill
  --status`.

  ## Usage

      mix rn.graph.backfill

  Prints the number of active git sources about to be reset, forces the
  resync, then prints how many `RepoSync` jobs were enqueued plus a
  `--status` hint.

  ## Status only

      mix rn.graph.backfill --status

  Prints `pending_chunks` counts by stage, in-flight `oban_jobs` counts by
  queue/state, and graph totals (entities/entity_mentions/entity_edges/
  chunks). Read-only — no cursor is cleared, nothing is enqueued.
  """

  use Mix.Task

  import Ecto.Query

  alias RetrievalNode.Ingest
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source

  @switches [status: :boolean]

  # run/1 ends in System.halt/1 (boot/0's ensure_all_started boots the full
  # supervision tree, which would otherwise keep the VM alive after this task
  # finishes), so it genuinely never returns — the spec tells dialyzer that's
  # intentional.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} = OptionParser.parse(args, strict: @switches)

    boot()

    if opts[:status] do
      print_status()
    else
      backfill()
    end

    # boot/0 brings up the *entire* supervision tree (Endpoint, Oban, the
    # embedding Serving/Warmer sub-tree, ...) since Oban.insert/1 needs a
    # running Oban instance to resolve its config — none of which has a
    # reason to keep running once this task's report is printed. Without an
    # explicit halt, `mix rn.graph.backfill` would hang after printing.
    System.halt(0)
  end

  # --- boot ---

  # This task only needs Repo + Oban's insert path — `Oban.insert/1` requires a
  # running Oban instance to resolve its config, but NOT running queues. It
  # deliberately disables local queue/plugin execution and the ~1.2 GB embedding
  # model load: actual ingestion/embedding runs on the already-supervised Oban
  # instance (dev server / systemd), never inside this short-lived task process.
  defp boot do
    Mix.Task.run("app.config")

    Application.put_env(:retrieval_node, :embedding_serving_start, false)
    Application.put_env(:retrieval_node, :reranking_serving_start, false)

    oban_config = Application.get_env(:retrieval_node, Oban, [])

    Application.put_env(
      :retrieval_node,
      Oban,
      Keyword.merge(oban_config, queues: [], plugins: [])
    )

    {:ok, _} = Application.ensure_all_started(:retrieval_node)

    # This node's own queues must never claim the very jobs this task
    # enqueues (it has no reason to run them, and its process lifetime ends
    # at System.halt/1 below, which would abandon any job it started).
    # `local_only:` is load-bearing: the default broadcasts the pause through
    # the shared-DB notifier to EVERY connected node — it would silently
    # pause the long-lived dev server's queues too (the ones that actually
    # need to keep running to process this backfill), and they'd stay paused
    # until that node restarts.
    Oban.pause_all_queues(local_only: true)
  end

  # --- backfill ---

  defp backfill do
    source_count =
      Repo.aggregate(
        from(s in Source, where: s.source_type == :git_repo and s.active == true),
        :count,
        :id
      )

    Mix.shell().info("Resetting sync watermark for #{source_count} active git source(s)...")

    case Ingest.force_full_resync_git_sources() do
      {:ok, enqueued} ->
        Mix.shell().info("""
        Enqueued #{enqueued} RepoSync job(s) with cleared watermarks.

        Jobs run on whatever node is running Oban queues (the dev server) —
        NOT this task. Monitor with:
          mix rn.graph.backfill --status
        """)

      {:error, reason} ->
        Mix.raise("failed to enqueue full resync: #{inspect(reason)}")
    end
  end

  # --- status (read-only) ---

  defp print_status do
    status = Ingest.backfill_status()

    Mix.shell().info("pending_chunks by status:")
    print_count_map(status.pending_chunks)

    Mix.shell().info("\noban_jobs (in-flight) by queue:")

    Enum.each(status.oban_jobs, fn {queue, by_state} ->
      Mix.shell().info("  #{queue}: #{inspect(by_state)}")
    end)

    Mix.shell().info("\ngraph totals:")
    print_count_map(status.graph)
  end

  defp print_count_map(map) do
    if map_size(map) == 0 do
      Mix.shell().info("  (none)")
    else
      Enum.each(map, fn {k, v} -> Mix.shell().info("  #{k}: #{v}") end)
    end
  end
end
