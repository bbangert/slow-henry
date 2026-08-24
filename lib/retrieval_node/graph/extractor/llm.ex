defmodule RetrievalNode.Graph.Extractor.LLM do
  @moduledoc """
  Deliberate seam for prose (Jira/Drive) entity extraction — not implemented
  yet. The corpus is currently 100% `git_repo`, so building an LLM-backed
  extractor now would be speculative: there is no prose source to extract
  entities/references from, and no eval corpus to validate an implementation
  against.

  When a `jira_project`/`drive_folder` source lands, implement `extract/3`
  against an LLM API following the Req/Finch client pattern in
  `RetrievalNode.Ingest.Jira`: a private `req/0` builder on the shared
  `RetrievalNode.Finch` pool, a `req_options/0` seam so tests inject a
  `Req.Test` plug instead of real HTTP, and manual 429/retry-after handling
  with Req's own `retry: false` (so a rate limit surfaces as a value the
  caller can act on instead of blocking on Req's built-in backoff).
  """
  @behaviour RetrievalNode.Graph.Extractor

  @impl true
  def extract(_input, _language, _opts), do: {:error, :not_configured}
end
