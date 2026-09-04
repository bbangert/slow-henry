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
# Selected at runtime via Application.get_env/2 so the changeable seams —
# chunking (tree-sitter NIF vs pure-Elixir heuristic), embedding (in-process
# Nx.Serving vs llama.cpp sidecar), and reranking (in-process cross-encoder
# Nx.Serving) — can be swapped per environment without touching call sites.
# `:test` overrides all three to keep the suite NIF-free and model-free.
config :retrieval_node,
  chunking_impl: RetrievalNode.Chunking.TreeSitterImpl,
  embedding_impl: RetrievalNode.Embedding.NxServingImpl,
  reranking_impl: RetrievalNode.Reranking.NxServingImpl

# Oban: `sync` is the only ingest queue left. It runs discovery
# (RepoSync/DriveSync/JiraSync — I/O-bound, watermark-driven "stage rows and
# notify") plus the daily GraphGc sweep below. Per-file work (scrub -> chunk
# -> embed -> write) no longer runs on Oban at all — it runs inside
# `Ingest.SourceOwner`, one GenServer boundary process per source with work,
# started on demand by a discovery worker's `notify/1` call (see that
# module's moduledoc: the redesign that replaced the old
# chunk/embed/upsert queues). Embedding concurrency across those
# concurrently-running owners is bounded by `Nx.Serving`'s own cross-caller
# batching (confirmed by the Phase 0 spike: concurrent `batched_run/2`
# callers coalesce into shared batches), not by a queue concurrency limit.
# Pruner keeps 14d of job history; Lifeline rescues jobs orphaned >20m. The
# Cron plugin below drives per-source watermark syncs via SyncScheduler (see
# its own comment for the fan-out rationale) and the daily GraphGc sweep,
# which fans out per source through `Ingest.SourceOwner.gc/1` (see that
# worker's moduledoc) — that's a `chunks`/graph-table write too, so it's
# funneled through the same single-writer-per-source boundary as everything
# else. Repo pool_size (dev/runtime) is raised to cover the `sync` queue's
# concurrency (3) plus concurrent `Ingest.SourceOwner` write transactions
# (one per source with work, held only for the duration of one file's
# write) plus MCP/ad-hoc connections.
config :retrieval_node, Oban,
  repo: RetrievalNode.Repo,
  queues: [sync: 3],
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
       {"*/30 * * * *", RetrievalNode.Ingest.Workers.SyncScheduler, args: %{"kind" => "drive"}},
       # Daily, off-peak: reaps entities orphaned by path-based chunk deletion (see GraphGc moduledoc)
       {"30 4 * * *", RetrievalNode.Ingest.Workers.GraphGc}
     ]}
  ]

# Embedding serving (Bumblebee/Nx.Serving over nomic-embed-text-v1.5). `compile`
# forces a JIT pass at init (batch_size 16); batch_timeout groups concurrent
# owner/query calls. The model emits 768-dim vectors; the impl
# Matryoshka-truncates to 384.
#
# `sequence_length` is a list of shape-bucket lengths rather than one fixed
# length: Bumblebee's tokenizer pads each input to the smallest bucket that
# fits it (`Bumblebee.Text.PreTrainedTokenizer`'s `:length` option), and
# `Nx.Serving` JIT-compiles one EXLA program per bucket (`Bumblebee.Shared.
# sequence_batch_keys/1`). A fixed 512 padded every chunk to 512 tokens
# regardless of actual length (~250ms/chunk observed), even though most chunks
# are far shorter. Bucketing means most chunks compute at 128 or 256 instead of
# always 512 — a real throughput win — at the cost of a few extra JIT passes
# (one per bucket) during boot warmup.
config :retrieval_node, RetrievalNode.Embedding.Serving,
  model: "nomic-ai/nomic-embed-text-v1.5",
  batch_size: 16,
  sequence_length: [128, 256, 512],
  batch_timeout_ms: 50

# Reranking serving (Bumblebee/Nx.Serving cross-encoder over
# cross-encoder/ms-marco-MiniLM-L-6-v2). Used only at query time, to rerank a
# handful of top-K retrieval candidates against the query — `compile` forces
# a JIT pass at init (batch_size 16, enough headroom for a typical top-K
# batch in one `batched_run/2` call).
#
# `sequence_length` buckets for the same reason as the embedding serving:
# most `{query, passage}` pairs are far shorter than the largest bucket, so
# bucketing lets short pairs compute at 256 instead of always paying for 512.
#
# `batch_timeout_ms` is 10ms (much tighter than the embedding serving's 50ms)
# because rerank calls arrive as one already-batched `batched_run/2` of ~50
# pairs from a single query — there's no stream of small concurrent calls to
# wait around and coalesce, and this path is on the latency-sensitive query
# request, not a background indexing job.
config :retrieval_node, RetrievalNode.Reranking.Serving,
  model: "cross-encoder/ms-marco-MiniLM-L-6-v2",
  batch_size: 16,
  sequence_length: [256, 512],
  batch_timeout_ms: 10

# Query-time reranking defaults OFF until the Phase-1.4 eval gate (MRR/Hit@k +
# p95 ≤ 300ms on the real corpus) proves it wins over plain RRF. `rerank_candidates`
# (the RRF candidate pool size fed into the cross-encoder) is 50 — roughly the
# reranker's practical latency budget in one `batched_run/2` call at batch_size 16
# (see the Reranking.Serving `batch_timeout_ms` comment above).
config :retrieval_node, rerank_default: false, rerank_candidates: 50

# Graph (entity-mention) leg of the hybrid RRF query — see HybridQuery
# moduledoc. The Phase-3.3 EXPLAIN + latency validation has passed on the
# full 595k-chunk corpus (vector/FTS/entity legs all index-driven; the graph
# leg adds ~71ms end-to-end) — it stays off by default as a latency/relevance
# tradeoff, not an open validation question: it costs real query latency for
# every request whether or not it improves result quality, and enabling it
# corpus-wide needs a relevance eval (the same bar the rerank feature's
# Phase-1.4 gate sets) to show that tradeoff is worth paying. Callers can opt
# in per-request today via the MCP `graph` field. `graph_leg_weight` keeps
# the as-yet-unproven-on-relevance leg from outvoting the tuned vector/FTS
# pair when a caller does enable it.
config :retrieval_node, graph_leg_default: false, graph_leg_weight: 0.5

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
