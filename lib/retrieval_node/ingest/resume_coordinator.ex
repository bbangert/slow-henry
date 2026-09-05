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
  gated off in the test env). Returns the number of sources drained.
  """
  @spec resume() :: non_neg_integer()
  def resume do
    source_ids = PendingChunks.pending_source_ids()
    max = max_concurrency()

    Logger.info(
      "Ingest.ResumeCoordinator: draining #{length(source_ids)} source(s) with pending work " <>
        "(max_concurrency=#{max})"
    )

    source_ids
    |> Task.async_stream(&SourceOwner.drain/1,
      max_concurrency: max,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    length(source_ids)
  end

  # `|| default` (not just get_env's default arg) so an explicit nil override
  # falls back too — a key set to nil is present, so get_env wouldn't default it.
  defp max_concurrency,
    do: Application.get_env(:retrieval_node, :resume_max_concurrency) || @default_max_concurrency
end
