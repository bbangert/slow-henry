defmodule RetrievalNodeWeb.Router do
  use RetrievalNodeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RetrievalNodeWeb.Layouts, :root}
    plug :protect_from_forgery
    # The root layout's inline theme script and LiveView's style attributes
    # need 'unsafe-inline'; everything else is same-origin.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline'; " <>
          "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " <>
          "connect-src 'self'; frame-ancestors 'none'"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", RetrievalNodeWeb do
    pipe_through :api
  end

  # Index inspection UI — LAN-only, no auth, like the MCP endpoint.
  scope "/", RetrievalNodeWeb do
    pipe_through :browser

    live "/", SourcesLive, :index
    live "/sources/:id", SourceLive, :show
    live "/search", SearchLive, :index
  end

  # Readiness probe — top-level (not under /api), no auth: a LAN-only slice
  # queried by a load balancer / uptime check, not an MCP client.
  scope "/", RetrievalNodeWeb do
    pipe_through :api

    get "/healthz", HealthController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:retrieval_node, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: RetrievalNodeWeb.Telemetry
    end
  end
end
