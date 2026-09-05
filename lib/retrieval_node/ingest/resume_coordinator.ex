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

  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}, {:continue, :resume}}

  @impl true
  def handle_continue(:resume, state) do
    resume()
    {:noreply, state}
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
    |> Task.async_stream(
      fn source_id ->
        try do
          {:drained, SourceOwner.drain(source_id)}
        catch
          kind, reason -> {:failed, source_id, kind, reason}
        end
      end,
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
    end)
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
