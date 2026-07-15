import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :retrieval_node, RetrievalNode.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # PostgreSQL 18 + pgvector on the standard port 5432 (see .devcontainer/).
  port: String.to_integer(System.get_env("PGPORT") || "5432"),
  database: "retrieval_node_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :retrieval_node, RetrievalNodeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xb1wf/fcqJ0Rk9mNgKpfMZUAAtw6bU69r+T/hwbLQMWYaM5H4XVE/KscBWTwAstZ",
  server: false

# Shrink the RRF candidate pool so filter-isolation tests can force pool
# starvation (proving filters apply inside both CTEs) without seeding 200+ rows.
config :retrieval_node, :rrf_candidate_pool, 5

# Keep the test suite NIF-free: use the pure-Elixir heuristic chunker rather
# than the tree-sitter NIF, so tests never load a native grammar or risk a
# C-level crash taking the runner down.
config :retrieval_node, chunking_impl: RetrievalNode.Chunking.HeuristicImpl

# Short chunk timeout so the guarded-timeout test resolves fast (not the 5s prod default).
config :retrieval_node, :chunking, call_timeout_ms: 100

# Oban in :manual testing mode — jobs are not run automatically; tests drive them
# via Oban.Testing (perform_job / assert_enqueued).
config :retrieval_node, Oban, testing: :manual

# Model-free embedding so the ingest pipeline (EmbedBatch) is testable without
# downloading nomic-embed-text or compiling EXLA.
config :retrieval_node, embedding_impl: RetrievalNode.Embedding.StubImpl

# Never start the real Nx.Serving sub-tree in test — it would load the ~1.2 GB
# model and JIT-compile it. StubImpl (above) stands in for RetrievalNode.Embedding.
config :retrieval_node, embedding_serving_start: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
