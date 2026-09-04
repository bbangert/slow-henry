defmodule RetrievalNode.Ingest.Workers.JiraSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Jira project. Append-only, same
  shape as `Ingest.Workers.RepoSync`/`DriveSync`: fetches issues resolved
  since the stored `resolutiondate_watermark` and stages one raw
  `pending_chunks` row per issue — never touches `chunks` directly.
  `Ingest.SourceOwner` is the only process that does. No deletion path today
  (Jira issues aren't removed the way a git path or Drive doc is).

  Staging the rows and advancing the watermark happen in ONE
  `Repo.transaction` (a plain write — this job's `unique` window on
  `source_id` makes it the sole writer of its cursor). After commit,
  `Ingest.SourceOwner.notify/1` wakes (or starts) the owner that applies the
  batch.

  A 429 returns `{:snooze, seconds}` (parsed from `Retry-After`) so rate
  limits don't burn attempts.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: {1, :hour},
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.{Jira, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    state = get_or_create_sync_state(source_id)
    watermark = Map.get(state.cursor || %{}, "resolutiondate_watermark")

    case Jira.fetch_resolved(source.identifier, watermark) do
      {:ok, []} ->
        SourceOwner.notify(source.id)
        :ok

      {:ok, issues} ->
        ingest(source, state, issues)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest(source, state, issues) do
    rows = Enum.map(issues, &raw_row(source, &1))

    new_watermark =
      issues
      |> Enum.map(& &1.resolutiondate)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    {:ok, :ok} =
      Repo.transaction(
        fn ->
          PendingChunks.insert_raw_all(rows)
          advance_watermark!(state, new_watermark)
          :ok
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
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

  defp advance_watermark!(_state, nil), do: :ok

  defp advance_watermark!(state, watermark) do
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
