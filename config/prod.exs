import Config

# Digested static files (built by `mix assets.deploy` before the release).
config :retrieval_node, RetrievalNodeWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
