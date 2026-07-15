defmodule RetrievalNode.Ingest.Jira do
  @moduledoc """
  Thin Jira REST client for incremental ingest of **resolved** issues. Uses a JQL
  `resolutiondate` watermark so each sync only fetches issues resolved since the
  last run (resolved/closed only — open issues churn and aren't worth indexing).

  Config: `config :retrieval_node, :jira, base_url:, email:, api_token:`. The Req
  request is built from `req_options/0`, which tests override (via `Req.Test`) to
  avoid real HTTP.
  """

  @resolved_statuses ~s("Resolved", "Closed", "Done")

  @type issue :: %{key: String.t(), text: String.t(), resolutiondate: String.t() | nil}

  @doc """
  Fetch issues in `project_key` resolved at/after `watermark` (an ISO-8601 date or
  nil for a full backfill). Returns `{:ok, issues}`, `{:snooze, seconds}` on a 429
  (rate limit), or `{:error, reason}`.
  """
  @spec fetch_resolved(String.t(), String.t() | nil) ::
          {:ok, [issue]} | {:snooze, pos_integer()} | {:error, term()}
  def fetch_resolved(project_key, watermark) do
    jql = build_jql(project_key, watermark)

    params = [
      jql: jql,
      fields: "summary,description,resolutiondate",
      maxResults: 50
    ]

    case Req.get(req(), url: "/rest/api/3/search", params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_issues(body)}
      {:ok, %{status: 429} = resp} -> {:snooze, retry_after(resp)}
      {:ok, %{status: status, body: body}} -> {:error, {:jira_http, status, truncate(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build the incremental JQL. Public for testing the watermark clause."
  @spec build_jql(String.t(), String.t() | nil) :: String.t()
  def build_jql(project_key, nil) do
    ~s|project = "#{project_key}" AND status in (#{@resolved_statuses}) ORDER BY resolutiondate ASC|
  end

  def build_jql(project_key, watermark) do
    ~s|project = "#{project_key}" AND status in (#{@resolved_statuses}) | <>
      ~s|AND resolutiondate >= "#{watermark}" ORDER BY resolutiondate ASC|
  end

  @doc "Map a Jira search response body into issues. Public for testing parsing."
  @spec parse_issues(map()) :: [issue]
  def parse_issues(%{"issues" => issues}) do
    Enum.map(issues, fn issue ->
      fields = issue["fields"] || %{}

      %{
        key: issue["key"],
        text: issue_text(fields),
        resolutiondate: fields["resolutiondate"]
      }
    end)
  end

  def parse_issues(_), do: []

  defp issue_text(fields) do
    [fields["summary"], extract_text(fields["description"])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Jira Cloud descriptions are Atlassian Document Format (nested content nodes);
  # walk it collecting text nodes. A plain string (older API) passes through.
  defp extract_text(nil), do: ""
  defp extract_text(text) when is_binary(text), do: text

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", &extract_text/1)
  end

  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(%{"type" => "hardBreak"}), do: "\n"
  defp extract_text(_), do: ""

  # Retry-After may be absent, an HTTP-date (RFC-allowed), or garbage — none of
  # which are a delta-seconds integer. Parse defensively and fall back to 60s so a
  # rate limit always yields {:snooze, _} rather than a raised (crashed) job.
  defp retry_after(resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, _} <- Integer.parse(value),
         true <- seconds > 0 do
      seconds
    else
      _ -> 60
    end
  end

  # Oban persists a failed job's error term to the jobs table (and logs it), so we
  # only keep a short, inspected prefix of the response body — enough to debug an
  # API error without spilling a full (potentially sensitive) payload into storage.
  defp truncate(body), do: body |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  defp req do
    cfg = Application.get_env(:retrieval_node, :jira, [])

    [
      base_url: cfg[:base_url] || "https://example.atlassian.net",
      auth: {:basic, "#{cfg[:email]}:#{cfg[:api_token]}"},
      # We handle 429 ourselves ({:snooze, _}); disable Req's own retry so it
      # doesn't block for ~a minute backing off before returning.
      retry: false,
      # Real requests share the app-wide Finch pool started in the supervision
      # tree. Listed before the req_options() merge so a test override (a
      # Req.Test plug) wins — Req.Test doesn't use Finch at all.
      finch: RetrievalNode.Finch
    ]
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  # Overridden in tests to inject a Req.Test plug (no real HTTP).
  defp req_options, do: Application.get_env(:retrieval_node, :jira_req_options, [])
end
