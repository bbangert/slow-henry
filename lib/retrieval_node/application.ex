defmodule RetrievalNode.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RetrievalNodeWeb.Telemetry,
      RetrievalNode.Repo,
      {DNSCluster, query: Application.get_env(:retrieval_node, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RetrievalNode.PubSub},
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

  defp mcp_server_start?, do: Application.get_env(:retrieval_node, :mcp_server_start, true)
end
