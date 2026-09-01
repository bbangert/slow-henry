defmodule RetrievalNode.Embedding.Warmer do
  @moduledoc """
  Fires `RetrievalNode.Embedding.Serving.warmup/0` after boot without blocking
  it, retrying on failure with a bounded exponential backoff.

  Lives under `RetrievalNode.Embedding.Supervisor`, a `:rest_for_one`
  supervisor ordered `[Serving, Warmer]`: a `Serving` crash restarts this
  process too, which is what re-warms the model (and re-resets the readiness
  flag) after a restart. `init/1` resets the flag synchronously — before this
  process is considered started — so there is no window where a stale `true`
  from before the crash is visible; `handle_continue/2` then runs the actual
  (slow) warmup after `init/1` returns, so supervisor startup isn't blocked on
  model load/JIT.

  ## Retry on transient failure

  `warmup/0` returning `:error` (a network blip fetching the model, a
  momentarily saturated scheduler, ...) used to be silently ignored: since
  `Serving.ready?/0` gates `/healthz`, one transient failure left the node
  reporting 503 forever, with nothing to trigger a further attempt short of a
  full `Serving` crash. `handle_info(:retry_warmup, state)` now retries with
  exponential backoff (1s, 2s, 4s, ... doubling up to a 60s cap) for up to 10
  attempts total, logging each attempt. If every attempt fails it logs an
  error and stops retrying — readiness then stays `false` until the
  supervisor restarts the `Serving`/`Warmer` pair (a fresh `Serving` crash, or
  a deploy).

  `:warmup_fun`, `:max_attempts`, `:base_backoff_ms` and `:max_backoff_ms` are
  test-only `start_link/1` opts (production never passes them, so it always
  gets the real `Serving.warmup/0` and the full backoff schedule above) —
  same seam precedent as `Supervisor`'s `:children` opt. Without the backoff
  overrides, exercising max-attempts exhaustion in a test would need to wait
  out the real ~5-minute schedule.
  """

  use GenServer
  require Logger

  alias RetrievalNode.Embedding.Serving

  @base_backoff_ms 1_000
  @max_backoff_ms 60_000
  @max_attempts 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Serving.reset_ready()

    state = %{
      warmup_fun: Keyword.get(opts, :warmup_fun, &Serving.warmup/0),
      max_attempts: Keyword.get(opts, :max_attempts, @max_attempts),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @base_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @max_backoff_ms),
      attempt: 0
    }

    {:ok, state, {:continue, :warmup}}
  end

  @impl true
  def handle_continue(:warmup, state), do: attempt_warmup(state)

  @impl true
  def handle_info(:retry_warmup, state), do: attempt_warmup(state)

  defp attempt_warmup(state) do
    attempt = state.attempt + 1

    case state.warmup_fun.() do
      :ok ->
        {:noreply, %{state | attempt: attempt}}

      :error ->
        if attempt >= state.max_attempts do
          Logger.error(
            "Embedding warmup failed after #{attempt}/#{state.max_attempts} attempts; " <>
              "readiness stays false until the supervisor restarts the Serving/Warmer pair"
          )

          {:noreply, %{state | attempt: attempt}}
        else
          delay_ms = backoff_ms(state, attempt)

          Logger.warning(
            "Embedding warmup failed (attempt #{attempt}/#{state.max_attempts}); " <>
              "retrying in #{delay_ms}ms"
          )

          Process.send_after(self(), :retry_warmup, delay_ms)
          {:noreply, %{state | attempt: attempt}}
        end
    end
  end

  # 1s, 2s, 4s, ... doubling each attempt, capped at 60s so a long outage
  # doesn't stretch retries out past a minute apart.
  defp backoff_ms(state, attempt),
    do: min(state.base_backoff_ms * Integer.pow(2, attempt - 1), state.max_backoff_ms)
end
