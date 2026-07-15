defmodule RetrievalNode.Embedding.Supervisor do
  @moduledoc """
  Supervises the embedding serving sub-tree: `RetrievalNode.Embedding.Serving`
  (the `Nx.Serving` process) followed by `RetrievalNode.Embedding.Warmer`.

  `:rest_for_one` (not `:one_for_one`) is the load-bearing choice: if `Serving`
  crashes and restarts, `Warmer` — which comes after it in the child order —
  restarts too, re-running `warmup/0` against the fresh serving. A `one_for_one`
  sibling would leave `Warmer` alone on a `Serving` crash, so the `/healthz`
  readiness flag would stay stuck at whatever it was before the crash instead of
  reflecting the (unwarmed) restarted process.

  Started only when `:embedding_serving_start` is true (default; `false` in
  `:test`, where `RetrievalNode.Embedding.StubImpl` is used instead and the real
  model must never load).
  """

  use Supervisor

  alias RetrievalNode.Embedding.{Serving, Warmer}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # `:children` is a test-only seam (RetrievalNode.Embedding.SupervisorTest):
    # the real Serving child loads a ~1.2 GB Bumblebee model, so tests swap it
    # for a stand-in to exercise rest_for_one restart semantics without a
    # model. Production never passes this opt, so it always gets the real pair.
    children = Keyword.get(opts, :children, [Serving, Warmer])

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
