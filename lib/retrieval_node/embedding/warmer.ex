defmodule RetrievalNode.Embedding.Warmer do
  @moduledoc """
  Fires `RetrievalNode.Embedding.Serving.warmup/0` after boot without blocking
  it.

  Lives under `RetrievalNode.Embedding.Supervisor`, a `:rest_for_one`
  supervisor ordered `[Serving, Warmer]`: a `Serving` crash restarts this
  process too, which is what re-warms the model (and re-resets the readiness
  flag) after a restart. `init/1` resets the flag synchronously — before this
  process is considered started — so there is no window where a stale `true`
  from before the crash is visible; `handle_continue/2` then runs the actual
  (slow) warmup after `init/1` returns, so supervisor startup isn't blocked on
  model load/JIT.
  """

  use GenServer

  alias RetrievalNode.Embedding.Serving

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Serving.reset_ready()
    {:ok, %{}, {:continue, :warmup}}
  end

  @impl true
  def handle_continue(:warmup, state) do
    Serving.warmup()
    {:noreply, state}
  end
end
