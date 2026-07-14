defmodule RetrievalNodeWeb.MCPPlug do
  @moduledoc """
  Mounts the Anubis `streamable_http` transport at `/mcp`.

  The Anubis plug does not filter by path (it handles whatever request reaches it),
  and it reads the raw request body itself — so it must run *before* the endpoint's
  `Plug.Parsers` consumes the JSON body. This thin wrapper delegates to it only for
  `/mcp` requests and passes everything else straight through to the rest of the
  pipeline (Parsers → Router).
  """
  @behaviour Plug

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: Transport

  @impl true
  def init(opts), do: Transport.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["mcp" | _]} = conn, opts), do: Transport.call(conn, opts)
  def call(conn, _opts), do: conn
end
