defmodule RetrievalNode.Ingest.Workers.JiraSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Jira project. Fetches issues resolved
  since the stored `resolutiondate_watermark`, inserts a raw `pending_chunks` row
  per issue, enqueues a `ChunkFiles` job, and advances the watermark. A 429 returns
  `{:snooze, seconds}` (parsed from `Retry-After`) so rate limits don't burn attempts.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: {1, :hour},
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.{Jira, PendingChunks}
  alias RetrievalNode.Ingest.Workers.ChunkFiles
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    state = get_or_create_sync_state(source_id)
    watermark = Map.get(state.cursor || %{}, "resolutiondate_watermark")

    case Jira.fetch_resolved(source.identifier, watermark) do
      {:ok, []} -> :ok
      {:ok, issues} -> ingest(source, state, issues)
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest(source, state, issues) do
    rows = Enum.map(issues, &raw_row(source, &1))
    {:ok, ids} = PendingChunks.insert_raw_all(rows)
    Enum.each(ids, &Oban.insert(ChunkFiles.new(%{"pending_chunk_id" => &1})))

    new_watermark =
      issues |> Enum.map(& &1.resolutiondate) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    advance_watermark(state, new_watermark)
    :ok
  end

  defp raw_row(source, issue) do
    %{
      source: "jira",
      source_id: source.id,
      source_type: "jira_project",
      lang: nil,
      natural_key: "jira:#{issue.key}",
      content_hash: :crypto.hash(:sha256, issue.text) |> Base.encode16(case: :lower),
      raw_content: issue.text,
      metadata: %{"issue_key" => issue.key, "resolutiondate" => issue.resolutiondate}
    }
  end

  defp advance_watermark(_state, nil), do: :ok

  defp advance_watermark(state, watermark) do
    state
    |> SyncState.changeset(%{
      cursor: Map.put(state.cursor || %{}, "resolutiondate_watermark", watermark),
      status: :idle,
      last_synced_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp get_or_create_sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end
end
