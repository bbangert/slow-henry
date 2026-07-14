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
  # Managed PG 18 cluster (pgvector 0.8.5) on 5433 — see config/dev.exs / scratchpad.
  port: String.to_integer(System.get_env("PGPORT") || "5433"),
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

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
