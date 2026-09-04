defmodule RetrievalNode.Ingest.Supervisor do
  @moduledoc """
  Supervises the per-source ingest boundary: `Ingest.SourceRegistry` (owner
  lookup by `source_id`), `Ingest.SourceSupervisor` (starts/restarts owners
  on demand), and — only on a VM that actually processes ingest — a one-shot
  boot Task that notifies every source with work waiting in `pending_chunks`
  (`Ingest.SourceOwner.resume_all/0`), so nothing staged before a restart or
  deploy sits unnoticed until that source's next discovery run.

  `:rest_for_one`: `SourceSupervisor` and the resume Task both depend on the
  Registry being up (an owner registers into it at start), so if the
  Registry dies, both restart with it; a `SourceSupervisor`-only restart
  doesn't need to touch the Registry.

  ## Why the resume kick is conditional

  A second VM against the same database — `mix rn.graph.backfill`, a bare
  `iex -S mix`, any admin task — must never become a second writer for a
  source another node already owns. That's exactly the multi-writer bug
  class this whole redesign exists to eliminate (see the plan's "Deployment
  premise: one BEAM node"). Those processes still boot the full OTP
  application (`Oban.insert/1` needs a running Oban to resolve its config),
  but they configure Oban with `queues: []` — this module's gate reads that
  back: `:ingest_resume_on_boot` true AND `Application.get_env(:retrieval_node, Oban)`
  has a non-empty `:queues` list AND no `:testing` key set (the test env
  runs Oban in `testing: :manual`, where nothing should auto-drain either)
  together mean "this VM actually runs ingest queues" — only then does it
  also own starting owners on boot. `SourceOwner.notify/1` has its own,
  separate guard against the mirror case (an admin task's short-lived VM
  calling `notify/1` directly) — see that module's moduledoc.
  """
  use Supervisor

  alias RetrievalNode.Ingest.SourceOwner

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        {Registry, keys: :unique, name: RetrievalNode.Ingest.SourceRegistry},
        {DynamicSupervisor,
         name: RetrievalNode.Ingest.SourceSupervisor,
         strategy: :one_for_one,
         max_restarts: 10,
         max_seconds: 60}
      ] ++ resume_children()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp resume_children do
    if ingest_vm?() do
      [
        %{
          id: :resume,
          start: {Task, :start_link, [&SourceOwner.resume_all/0]},
          restart: :temporary
        }
      ]
    else
      []
    end
  end

  defp ingest_vm? do
    Application.get_env(:retrieval_node, :ingest_resume_on_boot, true) and
      running_ingest_queues?()
  end

  defp running_ingest_queues? do
    oban_config = Application.get_env(:retrieval_node, Oban) || []
    queues = Keyword.get(oban_config, :queues, [])
    queues != [] and not Keyword.has_key?(oban_config, :testing)
  end
end
