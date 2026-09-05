defmodule RetrievalNode.Ingest.ResumeCoordinator do
  @moduledoc """
  Boot/recovery resume for the per-source ingest owners, with a global
  concurrency bound.

  On start it drains every source with work waiting in `pending_chunks`
  (`PendingChunks.pending_source_ids/0`), so rows staged before a restart or
  deploy aren't stuck until that source's next discovery tick. Unlike a bare
  `notify/1` fan-out — which starts EVERY pending source's owner at once, each
  loading a page of file content and running chunking independently — this
  drives `SourceOwner.drain/1` through `Task.async_stream` with a bounded
  `max_concurrency`, so a mass restart with a large backlog can't spike memory
  and CPU with unboundedly many concurrently-draining owners. (Embedding is
  separately bounded by `Nx.Serving`'s cross-caller batching.)

  It is a LONG-LIVED, restartable child of `Ingest.Supervisor`, not the old
  one-shot `:temporary` Task: after the initial drain it idles, and because
  `Ingest.Supervisor` is `:rest_for_one`, a crash of the Registry or
  `SourceSupervisor` restarts this coordinator too — re-running the resume so
  owners that died with them are restarted from the durable table rather than
  waiting for each source's next discovery tick.

  Override the bound with `config :retrieval_node, :resume_max_concurrency, n`.
  """
  use GenServer

  require Logger

  alias RetrievalNode.Ingest.{PendingChunks, SourceOwner}

  @default_max_concurrency 4
  # Per-source in-slot retries when an owner crashes mid-drain (keeps the slot
  # occupied, see drain_source/2), and the bounded backoff for a top-level
  # resume failure (keeps the permanent child from crash-looping the tree).
  @drain_retries 3
  @drain_retry_ms 50
  @resume_retry_base_ms 1_000
  @resume_retry_max_ms 60_000

  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{resume_attempts: 0}, {:continue, :resume}}

  @impl true
  def handle_continue(:resume, state), do: attempt_resume(state)

  @impl GenServer
  def handle_info(:retry_resume, state), do: attempt_resume(state)

  # resume/0 reads the DB (`pending_source_ids/0`) before any task is created,
  # so a transient DB outage at boot/recovery would raise straight out of the
  # continuation and, for this :permanent child, crash-loop until the
  # supervisor's restart intensity terminates the whole ingest tree. Guard it:
  # on a top-level failure, stay alive and retry with bounded backoff.
  defp attempt_resume(state) do
    resume()
    {:noreply, %{state | resume_attempts: 0}}
  rescue
    error -> schedule_retry(state, {:error, error})
  catch
    kind, reason -> schedule_retry(state, {kind, reason})
  end

  defp schedule_retry(state, reason) do
    attempts = state.resume_attempts + 1

    delay =
      min(@resume_retry_base_ms * Integer.pow(2, min(attempts - 1, 6)), @resume_retry_max_ms)

    Logger.error(
      "Ingest.ResumeCoordinator: resume failed (#{inspect(reason)}); retrying in #{delay}ms " <>
        "(attempt #{attempts})"
    )

    Process.send_after(self(), :retry_resume, delay)
    {:noreply, %{state | resume_attempts: attempts}}
  end

  @doc """
  Drain every source with pending work, at most `max_concurrency` at a time.
  Public so tests can drive it directly (the coordinator process itself is
  gated off in the test env). Returns the number of sources that drained
  successfully; a source whose drain fails is logged and skipped.
  """
  @spec resume() :: non_neg_integer()
  def resume do
    source_ids = PendingChunks.pending_source_ids()
    max = max_concurrency()

    Logger.info(
      "Ingest.ResumeCoordinator: draining #{length(source_ids)} source(s) with pending work " <>
        "(max_concurrency=#{max})"
    )

    # Catch inside the task so one source's failure (a start_child error, an
    # owner crash mid-drain) neither takes down the async_stream nor is silently
    # counted as success — log it and press on. Returns the count that DRAINED.
    source_ids
    |> Task.async_stream(&drain_source(&1, @drain_retries),
      max_concurrency: max,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn
      {:ok, {:drained, _}}, drained ->
        drained + 1

      {:ok, {:failed, source_id, kind, reason}}, drained ->
        Logger.error(
          "Ingest.ResumeCoordinator: drain failed source_id=#{source_id} " <>
            "#{kind}=#{inspect(reason)} — left for the source's next discovery tick"
        )

        drained

      # A task killed/force-exited by something outside its own try/catch (an
      # untrappable :kill can't be caught in-task) — log and skip so one dead
      # task can't FunctionClauseError-crash resume into a boot restart loop.
      {:exit, reason}, drained ->
        Logger.error("Ingest.ResumeCoordinator: resume task exited #{inspect(reason)}")
        drained
    end)
  end

  # Drain one source, RE-draining the SAME source in this same async_stream
  # slot if its owner crashes mid-drain. An owner is a :transient
  # DynamicSupervisor child, so a crash restarts it and its init drains again
  # on its own — if we instead freed this slot and let a new source start, that
  # restarted owner would drain OUTSIDE the concurrency bound (N + 1). Keeping
  # the slot on this source until it actually drains (or retries run out) holds
  # the bound; Registry uniqueness means our re-drain and the restarted owner
  # are the same process, so they don't double up.
  defp drain_source(source_id, retries) do
    {:drained, SourceOwner.drain(source_id)}
  catch
    _kind, _reason when retries > 0 ->
      Process.sleep(@drain_retry_ms)
      drain_source(source_id, retries - 1)

    kind, reason ->
      {:failed, source_id, kind, reason}
  end

  # Validate the configured bound; fall back to the default for a missing, nil,
  # or nonsense value rather than letting Task.async_stream raise during boot.
  defp max_concurrency do
    case Application.get_env(:retrieval_node, :resume_max_concurrency) do
      n when is_integer(n) and n > 0 ->
        n

      nil ->
        @default_max_concurrency

      other ->
        Logger.warning(
          "Ingest.ResumeCoordinator: invalid :resume_max_concurrency #{inspect(other)}, " <>
            "using #{@default_max_concurrency}"
        )

        @default_max_concurrency
    end
  end
end
