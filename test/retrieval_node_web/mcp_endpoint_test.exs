defmodule RetrievalNodeWeb.MCPEndpointTest do
  # Proves the Anubis transport is wired into the Endpoint at /mcp, ahead of
  # Plug.Parsers. The transport streams its response straight to the adapter (not
  # via send_resp), so ConnTest can't read the JSON-RPC body — the MCP protocol
  # behaviour is covered by RetrievalNode.MCP.ToolsTest (direct execute/2) and the
  # manual LAN drive in the plan's verify step. Here we assert the *routing*:
  # /mcp is owned by the transport, everything else flows on to the router.
  use RetrievalNodeWeb.ConnCase, async: false

  test "POST /mcp is handled (sent) by the MCP transport", %{conn: conn} do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", body)

    # The transport responded through the full endpoint pipeline (state :sent). A
    # Phoenix router miss would instead have flowed to the router (see below).
    assert conn.state == :sent
  end

  test "a non-/mcp path flows past MCPPlug to the Phoenix router", %{conn: conn} do
    # MCPPlug only intercepts /mcp; anything else reaches the router, which has no
    # matching route → a normal 404. That it 404s (rather than the transport
    # handling it) proves the path guard.
    conn = get(conn, "/definitely-not-a-route")
    assert conn.status == 404
  end
end
