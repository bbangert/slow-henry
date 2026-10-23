defmodule RetrievalNodeWeb.MCPPlug do
  @moduledoc """
  Mounts the Anubis `streamable_http` transport at `/mcp`.

  The Anubis plug does not filter by path (it handles whatever request reaches it),
  and it reads the raw request body itself — so it must run *before* the endpoint's
  `Plug.Parsers` consumes the JSON body. This thin wrapper delegates to it only for
  `/mcp` requests and passes everything else straight through to the rest of the
  pipeline (Parsers → Router).

  `GET /mcp` (the optional standalone server→client SSE stream) is answered with
  405, which the Streamable HTTP spec defines as "this server offers no SSE stream
  here". Our server never sends unsolicited messages — POST responses stream on
  their own connection — and Anubis keeps one GET stream per session, closing the
  old one when another arrives. A client holding two GET streams on one session
  therefore ping-pongs them forever (~17 reconnects/s, 26M requests in 18 days).
  """
  @behaviour Plug

  import Plug.Conn

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: Transport

  @impl true
  def init(opts), do: Transport.init(opts)

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["mcp" | _]} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "")
    |> halt()
  end

  def call(%Plug.Conn{path_info: ["mcp" | _]} = conn, opts), do: Transport.call(conn, opts)
  def call(conn, _opts), do: conn
end
