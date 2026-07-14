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
      # MCP server (streamable_http) — mounted on the Endpoint at /mcp. `start: true`
      # starts the session infra unconditionally; the default gates on the Phoenix
      # listener being up, which leaves it down under ConnTest (server: false).
      {RetrievalNode.MCP.Server, transport: {:streamable_http, start: true}},
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
end
