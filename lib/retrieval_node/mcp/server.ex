defmodule RetrievalNode.MCP.Server do
  @moduledoc """
  The MCP server for Retrieval Node — exposes the four retrieval tools over the
  `streamable_http` transport (mounted at `/mcp`, see `RetrievalNodeWeb.MCPPlug`).

  Tools call only the `Search`/`Ingest` contexts (and `Ingest.GitMirror` for git
  shell-outs); no tool module touches `Repo` or runs `System.cmd` directly.

  **LAN-only, no auth** for this slice — see `design-mcp.md` Risks. Bearer auth is
  mandatory before any internet exposure.
  """
  use Anubis.Server,
    name: "retrieval-node",
    version: "0.1.0",
    capabilities: [:tools]

  component(RetrievalNode.MCP.Tools.SemanticSearch)
  component(RetrievalNode.MCP.Tools.Grep)
  component(RetrievalNode.MCP.Tools.GetFile)
  component(RetrievalNode.MCP.Tools.ListRepos)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
