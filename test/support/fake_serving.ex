defmodule RetrievalNode.FakeServing do
  @moduledoc """
  Stand-in for either Bumblebee-backed `Serving` child (`Embedding.Serving`,
  loading a ~1.2 GB model, or `Reranking.Serving`, ~91 MB) in a `rest_for_one`
  supervisor test — neither model can be started in `test`. Only needs to
  occupy child position 1 of the `[Serving, Warmer]` pair and be killable; it
  doesn't need to be a real `Nx.Serving`.

  Registers under its own module name, so both `Embedding.SupervisorTest` and
  `Reranking.SupervisorTest` sharing this one module is safe: both suites are
  `async: false`, so they never run concurrently and never race for the
  `RetrievalNode.FakeServing` registered name.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}
end
