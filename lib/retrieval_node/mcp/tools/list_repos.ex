defmodule RetrievalNode.MCP.Tools.ListRepos do
  @moduledoc """
  List the sources currently indexed and searchable. Returns `{repo, source_type,
  default_ref}` entries — the repo slugs `grep`/`get_file` accept.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest

  # No inputs; an empty object schema.
  schema do
    %{}
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.json(Response.tool(), %{repos: Ingest.list_repos()}), frame}
  end
end
