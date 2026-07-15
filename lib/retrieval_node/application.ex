defmodule RetrievalNode.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        RetrievalNodeWeb.Telemetry,
        RetrievalNode.Repo,
        {DNSCluster, query: Application.get_env(:retrieval_node, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: RetrievalNode.PubSub},
        # Shared HTTP connection pool for the Jira/Drive ingest clients (Req is
        # configured to use this pool by name rather than starting its own
        # default instance per request).
        {Finch, name: RetrievalNode.Finch},
        # Runs tree-sitter parses (see Chunking.TreeSitterImpl) isolated from
        # their callers via async_nolink + yield/shutdown.
        {Task.Supervisor, name: RetrievalNode.ChunkTaskSupervisor}
      ] ++
        embedding_children() ++
        [
          {Oban, Application.fetch_env!(:retrieval_node, Oban)},
          # MCP server (streamable_http) — mounted on the Endpoint at /mcp. Anubis' own
          # `start` gate keys off the Phoenix serve-endpoints flag, which is off under
          # ConnTest, so we drive it from our own config (default on; a future
          # worker-only release can set `mcp_server_start: false`).
          {RetrievalNode.MCP.Server, transport: {:streamable_http, start: mcp_server_start?()}},
          # Start to serve requests, typically the last entry
          RetrievalNodeWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RetrievalNode.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RetrievalNodeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # The embedding serving sub-tree loads a ~1.2 GB model and JIT-compiles it —
  # never in :test, where RetrievalNode.Embedding.StubImpl stands in.
  defp embedding_children do
    if embedding_serving_start?(), do: [RetrievalNode.Embedding.Supervisor], else: []
  end

  defp mcp_server_start?, do: Application.get_env(:retrieval_node, :mcp_server_start, true)

  defp embedding_serving_start?,
    do: Application.get_env(:retrieval_node, :embedding_serving_start, true)
end
