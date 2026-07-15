defmodule RetrievalNode.Ingest.Drive do
  @moduledoc """
  Thin Google Drive client for incremental ingest via the **Changes API** cursor
  (`startPageToken`). Each sync fetches changes since the last cursor: changed Docs
  are exported as `text/markdown`; removed/unshared files are surfaced as deletions
  so their chunks can be pruned.

  Config: `config :retrieval_node, :drive, access_token:`. Req options are built
  from `req_options/0`, which tests override (via `Req.Test`) to avoid real HTTP.
  """

  @type doc :: %{doc_id: String.t(), name: String.t(), text: String.t()}
  @type changes :: %{changed: [doc], removed: [String.t()], cursor: String.t() | nil}

  @doc """
  Fetch changes since `cursor` (an opaque `startPageToken`). With `cursor == nil`
  (first run) there is no valid token to page from — Drive tokens are opaque, so we
  can't fabricate one — so we seed it from `changes/getStartPageToken` and return an
  empty page carrying that cursor; the next run pages real changes from it. Returns
  `{:ok, %{changed:, removed:, cursor:}}`, `{:snooze, seconds}` on a 429, or
  `{:error, reason}`.
  """
  @spec fetch_changes(String.t() | nil) ::
          {:ok, changes} | {:snooze, pos_integer()} | {:error, term()}
  def fetch_changes(nil) do
    case Req.get(req(), url: "/drive/v3/changes/startPageToken") do
      {:ok, %{status: 200, body: %{"startPageToken" => token}}} ->
        {:ok, %{changed: [], removed: [], cursor: token}}

      {:ok, %{status: 429} = resp} ->
        {:snooze, retry_after(resp)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:drive_http, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_changes(cursor) do
    params = [
      pageToken: cursor,
      fields: "newStartPageToken,changes(fileId,removed,file(id,name,mimeType))"
    ]

    case Req.get(req(), url: "/drive/v3/changes", params: params) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_changes(body)}
      {:ok, %{status: 429} = resp} -> {:snooze, retry_after(resp)}
      {:ok, %{status: status, body: body}} -> {:error, {:drive_http, status, truncate(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Split a Changes response into changed docs + removed ids + the next cursor."
  @spec parse_changes(map()) :: changes
  def parse_changes(body) do
    changes = body["changes"] || []

    {removed, present} =
      Enum.split_with(changes, fn c -> c["removed"] == true or is_nil(c["file"]) end)

    %{
      changed: present |> Enum.filter(&doc?/1) |> Enum.map(&to_doc/1),
      removed: Enum.map(removed, & &1["fileId"]),
      cursor: body["newStartPageToken"]
    }
  end

  @doc "Export a Google Doc as markdown text."
  @spec export_doc(String.t()) :: {:ok, String.t()} | {:error, term()}
  def export_doc(file_id) do
    case Req.get(req(),
           # Encode the id as a single path segment — it comes from a Drive API
           # response, so don't let it inject extra path/query structure.
           url: "/drive/v3/files/#{URI.encode(file_id, &URI.char_unreserved?/1)}/export",
           params: [mimeType: "text/markdown"]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:drive_http, status, truncate(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp doc?(change),
    do: get_in(change, ["file", "mimeType"]) == "application/vnd.google-apps.document"

  defp to_doc(change) do
    file = change["file"]
    %{doc_id: file["id"], name: file["name"], text: ""}
  end

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
    cfg = Application.get_env(:retrieval_node, :drive, [])

    [
      base_url: cfg[:base_url] || "https://www.googleapis.com",
      auth: {:bearer, cfg[:access_token] || ""},
      # We handle 429 ourselves ({:snooze, _}); disable Req's own retry.
      retry: false,
      # Real requests share the app-wide Finch pool started in the supervision
      # tree. Listed before the req_options() merge so a test override (a
      # Req.Test plug) wins — Req.Test doesn't use Finch at all.
      finch: RetrievalNode.Finch
    ]
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  defp req_options, do: Application.get_env(:retrieval_node, :drive_req_options, [])
end
