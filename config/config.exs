# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :retrieval_node,
  ecto_repos: [RetrievalNode.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Register the pgvector Postgrex type module for every environment. Without
# this, the `vector` OID has no encoder/decoder and `<=>` cosine comparisons
# silently misbehave (or fail at param-binding with a cryptic Postgrex error).
config :retrieval_node, RetrievalNode.Repo, types: RetrievalNode.PostgrexTypes

# Swappable subsystem implementations (behaviours defined in later phases).
# Selected at runtime via Application.get_env/2 so the two changeable seams —
# chunking (tree-sitter NIF vs pure-Elixir heuristic) and embedding (in-process
# Nx.Serving vs llama.cpp sidecar) — can be swapped per environment without
# touching call sites. `:test` overrides `chunking_impl` to keep tests NIF-free.
config :retrieval_node,
  chunking_impl: RetrievalNode.Chunking.TreeSitterImpl,
  embedding_impl: RetrievalNode.Embedding.NxServingImpl

# Oban ingest pipeline. Queue concurrencies (design-oban §2): sync I/O-bound;
# chunk CPU+NIF (bounded so it doesn't monopolize dirty schedulers); embed=1
# (single Nx.Serving, must not starve the MCP endpoint); upsert cheap Postgres.
# Pruner keeps 14d of job history; Lifeline rescues jobs orphaned >20m. The Cron
# plugin (per-source watermark sync entrypoints) is added with the workers in the
# next step. Repo pool_size is raised (dev/runtime) to num_queues + sum(limits) + buffer.
config :retrieval_node, Oban,
  repo: RetrievalNode.Repo,
  queues: [sync: 3, chunk: 2, embed: 1, upsert: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 14},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)},
    # Cron fans out per source kind (RepoSync */15, JiraSync hourly, DriveSync */30)
    # via SyncScheduler, since source ids are dynamic. Only active when Oban is in
    # the supervision tree (Phase 8); disabled in :test.
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", RetrievalNode.Ingest.Workers.SyncScheduler, args: %{"kind" => "git"}},
       {"0 * * * *", RetrievalNode.Ingest.Workers.SyncScheduler, args: %{"kind" => "jira"}},
       {"*/30 * * * *", RetrievalNode.Ingest.Workers.SyncScheduler, args: %{"kind" => "drive"}}
     ]}
  ]

# Embedding serving (Bumblebee/Nx.Serving over nomic-embed-text-v1.5). `compile`
# forces a JIT pass at init (batch_size 16, sequence_length 512); batch_timeout
# groups concurrent query/indexing calls. The model emits 768-dim vectors; the
# impl Matryoshka-truncates to 384.
config :retrieval_node, RetrievalNode.Embedding.Serving,
  model: "nomic-ai/nomic-embed-text-v1.5",
  batch_size: 16,
  sequence_length: 512,
  batch_timeout_ms: 50

# EXLA as the global Nx default backend — without this, any tensor op NOT
# routed through the serving's own `defn_options: [compiler: EXLA]` (e.g. the
# Matryoshka truncation math in NxServingImpl) would silently run on
# Nx.BinaryBackend, 10-100x slower on the arm64 deploy target. `/healthz`'s
# `nx_backend` gate asserts this stayed set (design-build.md §4 step 2).
config :nx, default_backend: EXLA.Backend

# Configures the endpoint
config :retrieval_node, RetrievalNodeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RetrievalNodeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RetrievalNode.PubSub,
  live_view: [signing_salt: "EfjADv/k"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
