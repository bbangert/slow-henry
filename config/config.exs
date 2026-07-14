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
