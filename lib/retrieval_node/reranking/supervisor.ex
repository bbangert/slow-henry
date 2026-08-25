defmodule RetrievalNode.Reranking.Supervisor do
  @moduledoc """
  Supervises the reranking serving sub-tree: `RetrievalNode.Reranking.Serving`
  (the `Nx.Serving` process) followed by `RetrievalNode.Reranking.Warmer`.

  `:rest_for_one` (not `:one_for_one`) is the load-bearing choice: if `Serving`
  crashes and restarts, `Warmer` — which comes after it in the child order —
  restarts too, re-running `warmup/0` against the fresh serving. A `one_for_one`
  sibling would leave `Warmer` alone on a `Serving` crash, so the `/healthz`
  readiness flag would stay stuck at whatever it was before the crash instead of
  reflecting the (unwarmed) restarted process.

  Started only when `:reranking_serving_start` is true (default; `false` in
  `:test`, where `RetrievalNode.Reranking.StubImpl` is used instead and the real
  model — ~91 MB, far smaller than the embedding model but still not welcome in
  the test env — must never load).
  """

  use Supervisor

  alias RetrievalNode.Reranking.{Serving, Warmer}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  # Exposed so tests can assert the production pair WITHOUT materializing
  # child specs: `Serving.child_spec/1` builds the Bumblebee serving, which
  # loads (and on a cold cache DOWNLOADS) the real model — `Supervisor.init([])`
  # in a test was silently pulling the model from HuggingFace in CI.
  @doc false
  def default_children, do: [Serving, Warmer]

  @impl true
  def init(opts) do
    # `:children` is a test-only seam (RetrievalNode.Reranking.SupervisorTest):
    # the real Serving child loads a ~91 MB Bumblebee model, so tests swap it
    # for a stand-in to exercise rest_for_one restart semantics without a
    # model. Production never passes this opt, so it always gets the real pair.
    children = Keyword.get(opts, :children, default_children())

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
