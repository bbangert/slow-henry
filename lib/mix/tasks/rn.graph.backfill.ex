defmodule Mix.Tasks.Rn.Graph.Backfill do
  @shortdoc "Forces a full re-derive of every active git source to backfill graph extraction"

  @moduledoc """
  Forces a full re-derive of every active git source's chunks/graph rows, so
  newly-added graph extraction (entities/entity_mentions/entity_edges)
  backfills onto the whole corpus — not just files touched by future syncs.

  ## Mechanism

  Enqueues a `RepoSync` job per active, syncable (`policy: :allow`) git source with `"full" => true`
  (`Ingest.force_full_resync_git_sources/0,1`). `RepoSync` treats `full?` as
  "diff against nil regardless of the stored cursor" — it stages every file
  in the repo, each row tagged `force: true`, and still advances the
  watermark to `HEAD` on completion (no cursor is cleared: append-only
  discovery has nothing to clear). The source's `Ingest.SourceOwner` picks up
  those staged rows the normal way and re-chunks/re-extracts each file
  through `Ingest.FileIngest.apply/2`.

  ## Sources with a sync already in flight

  `RepoSync` is the sole active sync per source, so a plain sync that is still
  waiting (`available`/`scheduled`/`retryable`) is UPGRADED in place to the full
  sync (reported as "upgraded"). One that is `executing` cannot be replaced: the
  source is listed as busy and no full job is queued. Re-run the task after that
  sync finishes — it is idempotent and will enqueue the full sync then.

  ## Idempotency and cost

  `force: true` re-chunks/re-extracts even though a file's content is
  unchanged, but `FileIngest` REUSES existing embeddings wherever
  `(chunk_key, content_hash)` matches an already-persisted chunk (see its
  moduledoc's "Embedding reuse") — so this is now cheap despite touching the
  whole corpus, unlike the old pipeline's full re-embed (which used to cost
  hours). Chunks are keyed on `chunk_key`/`content_hash` regardless, so
  re-processing unchanged content upserts the same row rather than
  duplicating it.

  ## Where the work actually happens

  This task only enqueues jobs. It boots like `mix rn.seed` (`Seed.boot/0`:
  no queues, no plugins, servings off), so it runs no queues of its own and
  starts no `Ingest.SourceOwner` processes (`Ingest.Supervisor`'s `queues: []`
  gate). The enqueued `RepoSync` jobs, and the
  `Ingest.SourceOwner` processes that apply the rows they stage, run on
  whatever node is actually running Oban queues (the dev server, or the
  production Oban instance), NOT this admin task's process. That other
  process must already be up (or come up) for the backfill to make progress;
  watch it with `mix rn.graph.backfill --status`.

  ## Usage

      mix rn.graph.backfill

  Prints the number of active git sources, forces the full re-derive, then
  prints how many `RepoSync` jobs were enqueued plus a `--status` hint.

  ## Targeted re-sync

      mix rn.graph.backfill --source my-repo --source other-repo

  Repeatable `--source <name-or-identifier>` enqueues a full re-derive for
  ONLY the named syncable git source(s) — matched against either a source's
  `name` or its `identifier` — instead of paying the full-corpus cost. Any
  name that matches no syncable git source aborts the whole run (nothing is
  enqueued) with the unmatched name(s) listed.

  ## Status only

      mix rn.graph.backfill --status

  Prints `pending_chunks` counts by status, in-flight `oban_jobs` counts by
  queue/state, graph totals (entities/entity_mentions/entity_edges/chunks),
  `failed_files` (rows an owner gave up on after max attempts), and `owners`
  (how many `Ingest.SourceOwner` processes are currently registered on the
  VM actually running ingest — always 0 on this task's own short-lived VM).
  Read-only — nothing is enqueued.
  """

  use Mix.Task

  import Ecto.Query

  alias Mix.Tasks.Rn.Seed
  alias RetrievalNode.Ingest
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source

  # source: :keep collects one {:source, value} pair per repeated flag
  # (never overwrites/merges), so --source a --source b survives parse_args
  # as [source: "a", source: "b"] for run/1 to Keyword.get_values/2 out.
  @switches [status: :boolean, source: :keep]

  # run/1 ends in System.halt/1 (the booted supervision tree would otherwise
  # keep the VM alive), so it never returns.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        Seed.boot()

        if opts[:status] do
          print_status()
        else
          backfill(Keyword.get_values(opts, :source))
        end

        # Seed.boot/0 brings up the whole supervision tree (Endpoint, Oban, ...)
        # since Oban.insert/1 needs a running Oban instance; nothing has a reason
        # to keep running once the report is printed, so halt explicitly.
        System.halt(0)

      {:error, message} ->
        # Raised BEFORE boot: an unrecognized flag (`--statsu`, a typo of
        # `--status`) must never silently fall through to the full-resync branch.
        Mix.raise(message)
    end
  end

  # Pulled out of run/1 so it's testable without booting the app.
  @spec parse_args([binary()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, extra_args, invalid} ->
        {:error, usage_error(extra_args, invalid)}
    end
  end

  defp usage_error(extra_args, invalid) do
    offenders =
      Enum.map(invalid, fn
        {flag, nil} -> flag
        {flag, value} -> "#{flag}=#{value}"
      end) ++ extra_args

    "unrecognized option(s)/argument(s): #{Enum.join(offenders, ", ")}\n\n" <>
      "Usage:\n" <>
      "  mix rn.graph.backfill                              # force a full re-sync backfill\n" <>
      "  mix rn.graph.backfill --source NAME [--source ...]  # targeted re-sync backfill\n" <>
      "  mix rn.graph.backfill --status                      # read-only status report"
  end

  # --- backfill ---

  defp backfill([]) do
    source_count =
      Repo.aggregate(
        from(s in Source,
          where: s.source_type == :git_repo and s.active == true and s.policy == :allow
        ),
        :count,
        :id
      )

    Mix.shell().info("Forcing a full re-derive for #{source_count} syncable git source(s)...")

    report_resync(Ingest.force_full_resync_git_sources(), "full resync")
  end

  defp backfill(source_names) do
    Mix.shell().info(
      "Forcing a full re-derive for #{length(source_names)} named git source(s): " <>
        "#{Enum.join(source_names, ", ")}..."
    )

    report_resync(Ingest.force_full_resync_git_sources(source_names), "targeted resync")
  end

  defp report_resync(result, label) do
    case result do
      {:ok, %{enqueued: enqueued, upgraded: upgraded, busy: busy}} ->
        Mix.shell().info("""
        Full-resync RepoSync jobs: #{enqueued} enqueued, #{upgraded} upgraded from a waiting plain sync, #{length(busy)} busy.

        Jobs run on whatever node is running Oban queues (the dev server) —
        NOT this task. Monitor with:
          mix rn.graph.backfill --status
        """)

        report_busy(busy)

      {:error, {:unknown_sources, unknown}} ->
        Mix.raise("unknown source name(s)/identifier(s): #{Enum.join(unknown, ", ")}")

      {:error, reason} ->
        Mix.raise("failed to enqueue #{label}: #{inspect(reason)}")
    end
  end

  defp report_busy([]), do: :ok

  defp report_busy(busy) do
    Mix.shell().info("""
    Busy (a sync is executing and can't be upgraded; no full job was queued):
    #{Enum.map_join(busy, "\n", &"  - #{&1.name}")}

    Re-run this task once their in-flight sync finishes (it is idempotent):
      mix rn.graph.backfill#{Enum.map_join(busy, "", &" --source #{shell_quote(&1.name)}")}
    """)
  end

  # POSIX single-quoting: names are free-form (spaces, apostrophes), and the
  # printed command must be runnable as-is.
  @doc false
  def shell_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

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

    Mix.shell().info("\nfailed_files (gave up after max attempts): #{status.failed_files}")
    Mix.shell().info("owners (SourceOwner processes registered on this VM): #{status.owners}")
  end

  defp print_count_map(map) do
    if map_size(map) == 0 do
      Mix.shell().info("  (none)")
    else
      Enum.each(map, fn {k, v} -> Mix.shell().info("  #{k}: #{v}") end)
    end
  end
end
