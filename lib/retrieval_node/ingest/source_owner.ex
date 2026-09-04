defmodule RetrievalNode.Ingest.SourceOwner do
  @moduledoc """
  The ingest pipeline's Boundary layer (per *Designing Elixir Systems with
  OTP*'s Data/Functions/Boundary split): one `GenServer` per source, the ONLY
  process that writes `chunks` rows for that source. Its mailbox is the
  serialization point — not a DB lock, generation counter, or tombstone —
  because a single BEAM node is the deployment premise (see the plan). Two
  concurrent `notify/1` calls for the same source coalesce onto the same
  process; two rows for the same file can never race each other into
  `Ingest.FileIngest.apply/2` because this process only ever runs one at a
  time.

  ## The mailbox: `pending_chunks` IS the durable queue

  Discovery workers (`RepoSync`/`DriveSync`/`JiraSync`) only ever append rows
  — content rows and deletion entries — then call `notify/1`. They never touch
  `chunks`. The raw rows themselves are this source's per-file FIFO: the
  `pending_chunks` bigserial `id` is arrival order, which is version order,
  which is the order `Ingest.FileIngest.apply/2` is called in (after
  collapsing to the newest row per file — see `pass/1` below). Nothing about
  ordering lives in this process's memory; it lives in the table.

  ## Lifecycle

  Started on demand (`notify/1`/`drain/1` both start-if-absent) under
  `Ingest.SourceSupervisor`, registered via `Ingest.SourceRegistry` so at most
  one owner ever exists per `source_id` at a time (`Registry, keys: :unique`
  is the actual uniqueness guarantee — nothing else enforces it). It stops
  itself after `@idle_ms` of inactivity (90 active sources should not mean 90
  live processes between syncs) — `:transient` restart means that normal stop
  is left alone, but a crash (a poison file this process's own `try/rescue`
  didn't contain, a NIF-level fault) is restarted by `SourceSupervisor`.

  A fresh owner (first start, OR a restart after a crash) does exactly the
  same thing either way: read `pending_chunks` for this source and drain it.
  Nothing is lost (the table survives the process) and nothing is duplicated
  (`Ingest.FileIngest.apply/2` is idempotent per `chunk_key`, and only deletes
  its raw row on success — a crash mid-apply leaves the row for the restarted
  owner to pick up and re-apply from scratch).
  """

  use GenServer

  require Logger

  alias RetrievalNode.Ingest.{FileIngest, PendingChunks}

  @max_file_attempts 5
  @rows_per_pass 50
  @idle_ms 60_000

  @type source_id :: binary()

  # --- API -------------------------------------------------------------

  @doc false
  def child_spec(source_id) do
    %{
      id: {__MODULE__, source_id},
      start: {__MODULE__, :start_link, [source_id]},
      restart: :transient
    }
  end

  @doc false
  def start_link(source_id) do
    GenServer.start_link(__MODULE__, source_id, name: via(source_id))
  end

  @doc """
  Max attempts before a row is left marked instead of retried. Public (not a
  private module attribute duplicated in two places) because `PendingChunks`'
  `drainable/2` and `failed_count/0` both need the exact same ceiling.
  """
  @spec max_file_attempts() :: pos_integer()
  def max_file_attempts, do: @max_file_attempts

  @doc """
  Fire-and-forget "you have mail" for `source_id`: starts its owner if one
  isn't running, else wakes the running one — either way, `init`'s (or the
  running owner's) `handle_continue(:drain, _)` picks up whatever is now in
  the table. `:ok` in every case; this is a hint, not a guarantee the drain
  has happened by the time it returns (`drain/1` is the synchronous version).

  Two gates make this a no-op in situations where starting an owner would be
  wrong:

    * `Application.get_env(:retrieval_node, :source_owner_notify, true)` false
      (the test env) — discovery-worker tests must not spawn owner processes
      that then race the DataCase sandbox; owner tests start owners
      explicitly.
    * `Ingest.SourceSupervisor` not registered at all — this VM isn't running
      the ingest supervision tree in the way that starting owners here would
      be safe (see `Ingest.Supervisor`'s moduledoc: an admin task, or the
      hot-reloaded dev node between an old and new `Ingest.Supervisor`).
      Logs a warning and returns `:ok` — rows are durable, so whichever VM
      does own ingest picks this source up on its own next boot/notify.
  """
  @spec notify(source_id()) :: :ok
  def notify(source_id) do
    cond do
      not notify_enabled?() ->
        :ok

      is_nil(Process.whereis(RetrievalNode.Ingest.SourceSupervisor)) ->
        Logger.warning(
          "Ingest.SourceOwner.notify/1: SourceSupervisor not running in this VM " <>
            "(admin task, or dev node mid-restart) — rows are durable, source_id=#{source_id}"
        )

        :ok

      true ->
        start_or_notify(source_id, 3)
    end
  end

  defp notify_enabled?,
    do: Application.get_env(:retrieval_node, :source_owner_notify, true)

  defp start_or_notify(source_id, 0) do
    Logger.warning(
      "Ingest.SourceOwner.notify/1: gave up after 3 tries (owner kept exiting mid-lookup) " <>
        "source_id=#{source_id}"
    )

    :ok
  end

  defp start_or_notify(source_id, tries_left) do
    case DynamicSupervisor.start_child(
           RetrievalNode.Ingest.SourceSupervisor,
           child_spec(source_id)
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        try do
          GenServer.call(pid, :notify)
          :ok
        catch
          # The owner was idle-stopping between our lookup and this call —
          # loop and either find it gone (start a fresh one) or find whatever
          # replaced it.
          :exit, _reason -> start_or_notify(source_id, tries_left - 1)
        end

      {:error, reason} ->
        Logger.warning(
          "Ingest.SourceOwner.notify/1: start_child failed source_id=#{source_id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Synchronous drain: ensure `source_id`'s owner is started, then run passes
  until nothing is drainable. For tests and ops — bypasses the
  `:source_owner_notify` gate entirely (a caller asking to drain wants it to
  actually happen).

  Returns **cumulative** stats — every pass this owner has run since it
  started, not just the passes this call's own loop drove. A fresh owner's
  `init/1` runs its first pass via `handle_continue` before handling ANY
  queued message (OTP's own guarantee), so a `drain/1` call racing right
  after start would otherwise see only its own (often zero-row) loop and
  undercount — or on an already-drained queue, report zero applied even
  though the continue-triggered pass already did the work. Accumulating in
  the owner's state across every pass (`handle_continue`, `handle_info(:drain)`,
  and this call's own loop alike) makes the count immune to that ordering.
  """
  @spec drain(source_id()) :: {:ok, map()}
  def drain(source_id) do
    pid = ensure_started(source_id)
    GenServer.call(pid, :drain, :infinity)
  end

  defp ensure_started(source_id) do
    case DynamicSupervisor.start_child(
           RetrievalNode.Ingest.SourceSupervisor,
           child_spec(source_id)
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc "Stop `source_id`'s owner if one is registered (a no-op otherwise). Tests use this in `on_exit`."
  @spec stop(source_id()) :: :ok
  def stop(source_id) do
    case whereis(source_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc "The registered pid for `source_id`'s owner, or `nil` if none is running."
  @spec whereis(source_id()) :: pid() | nil
  def whereis(source_id), do: GenServer.whereis(via(source_id))

  @doc """
  Notifies every source with at least one drainable row
  (`PendingChunks.pending_source_ids/0`) — called by `Ingest.Supervisor`'s
  boot Task (gated so it only runs on a VM that actually processes ingest;
  see that module's moduledoc) so rows staged before a restart aren't
  silently stuck until their source's next discovery run.
  """
  @spec resume_all() :: :ok
  def resume_all do
    source_ids = PendingChunks.pending_source_ids()

    Logger.info(
      "Ingest.SourceOwner.resume_all/0: notifying #{length(source_ids)} source(s) with pending work"
    )

    Enum.each(source_ids, &notify/1)
    :ok
  end

  defp via(source_id), do: {:via, Registry, {RetrievalNode.Ingest.SourceRegistry, source_id}}

  # --- callbacks ---------------------------------------------------------

  @impl GenServer
  def init(source_id),
    do: {:ok, %{source_id: source_id, stats: empty_stats()}, {:continue, :drain}}

  @impl GenServer
  def handle_continue(:drain, state), do: run_one_pass(state)

  @impl GenServer
  def handle_info(:drain, state), do: run_one_pass(state)

  @impl GenServer
  def handle_info(:timeout, state) do
    if PendingChunks.drainable?(state.source_id) do
      {:noreply, state, {:continue, :drain}}
    else
      {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_call(:notify, _from, state), do: {:reply, :ok, state, {:continue, :drain}}

  @impl GenServer
  def handle_call(:drain, _from, state) do
    state = drain_loop(state)
    {:reply, {:ok, state.stats}, state, @idle_ms}
  end

  # A pass that came back full (rows_per_pass rows drained) means more may be
  # waiting right behind it — send ourselves another :drain rather than
  # looping inline, so a :notify/:drain call arriving mid-drain still gets to
  # interleave (the mailbox stays responsive between passes). Every pass's
  # stats are merged into the owner's cumulative state.stats (see drain/1's
  # @doc) regardless of which code path ran it.
  defp run_one_pass(state) do
    {stats, full_batch?} = pass(state.source_id)
    state = %{state | stats: merge_stats(state.stats, stats)}

    if full_batch? do
      send(self(), :drain)
      {:noreply, state}
    else
      {:noreply, state, @idle_ms}
    end
  end

  defp drain_loop(state) do
    {stats, full_batch?} = pass(state.source_id)
    state = %{state | stats: merge_stats(state.stats, stats)}

    if full_batch? or PendingChunks.drainable?(state.source_id) do
      drain_loop(state)
    else
      state
    end
  end

  defp empty_stats,
    do: %{applied: 0, skipped: 0, failed: 0, superseded: 0, embedded: 0, reused: 0}

  defp merge_stats(a, b), do: Map.merge(a, b, fn _k, v1, v2 -> v1 + v2 end)

  # --- one pass ------------------------------------------------------------

  defp pass(source_id) do
    rows = PendingChunks.drainable(source_id, limit: @rows_per_pass)
    full_batch? = length(rows) == @rows_per_pass

    {kept, superseded} = collapse(rows)

    stats =
      Enum.reduce(kept, %{empty_stats() | superseded: superseded}, fn row, stats ->
        apply_row(source_id, row, stats)
      end)

    Logger.info(
      "Ingest.SourceOwner pass source_id=#{source_id} applied=#{stats.applied} " <>
        "skipped=#{stats.skipped} failed=#{stats.failed} superseded=#{stats.superseded} " <>
        "embedded=#{stats.embedded} reused=#{stats.reused}"
    )

    {stats, full_batch?}
  end

  # Group the pass's rows by file identity, keep only the newest (highest id)
  # per group, and delete the superseded older rows in one shot — they're
  # never applied at all. A superseded row's `force: true` carries forward
  # onto the kept row: a backfill request racing a later plain sync must not
  # be silently dropped just because the plain sync's row arrived after it.
  defp collapse(rows) do
    {kept, superseded_ids} =
      rows
      |> Enum.group_by(&collapse_key/1)
      |> Enum.reduce({[], []}, fn {_key, group}, {kept_acc, superseded_acc} ->
        [newest | rest] = Enum.sort_by(group, & &1.id, :desc)
        force? = newest.force or Enum.any?(rest, & &1.force)

        {[%{newest | force: force?} | kept_acc], Enum.map(rest, & &1.id) ++ superseded_acc}
      end)

    if superseded_ids != [], do: PendingChunks.delete_by_ids(superseded_ids)

    {Enum.sort_by(kept, & &1.id), length(superseded_ids)}
  end

  defp collapse_key(row),
    do: RetrievalNode.Ingest.file_identity(row.source_type, row.metadata) || row.natural_key

  defp apply_row(source_id, row, stats) do
    force? = row.force
    row = PendingChunks.mark_attempt(row)
    on_parse_crash = if row.attempts >= @max_file_attempts, do: :heuristic, else: :error

    result =
      try do
        FileIngest.apply(row, force: force?, on_parse_crash: on_parse_crash)
      rescue
        error -> {:error, {error, __STACKTRACE__}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, summary} ->
        # `embedded`/`reused` only exist on an :indexed summary; deletions and
        # unindexable files embed nothing.
        %{
          stats
          | applied: stats.applied + 1,
            embedded: stats.embedded + Map.get(summary, :embedded, 0),
            reused: stats.reused + Map.get(summary, :reused, 0)
        }

      {:skipped, :unchanged} ->
        %{stats | skipped: stats.skipped + 1}

      {:error, reason} ->
        handle_failure(source_id, row, reason)
        %{stats | failed: stats.failed + 1}
    end
  end

  defp handle_failure(source_id, row, reason) do
    minutes = min(Integer.pow(2, row.attempts), 30)
    retry_after = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
    PendingChunks.mark_failure(row, reason, retry_after)

    message =
      "Ingest.SourceOwner: apply failed source_id=#{source_id} pending_chunk_id=#{row.id} " <>
        "attempts=#{row.attempts} reason=#{inspect(reason)}"

    if row.attempts >= @max_file_attempts do
      Logger.error(message <> " — giving up after #{row.attempts} attempts")
    else
      Logger.warning(message)
    end
  end
end
