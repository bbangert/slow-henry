defmodule RetrievalNode.Ingest.Workers.JiraSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Jira project. Append-only, same
  shape as `Ingest.Workers.RepoSync`/`DriveSync`: fetches issues resolved
  since the stored `resolutiondate_watermark` and stages one raw
  `pending_chunks` row per issue — never touches `chunks` directly.
  `Ingest.SourceOwner` is the only process that does. No removal path today
  (Jira issues aren't removed the way a git path or Drive doc is) — but an
  issue whose text comes back binary (`Chunking.binary_content?/1`, a
  defensive check; Jira's own ADF text extraction shouldn't produce this)
  still stages a deletion entry rather than being silently dropped by
  `PendingChunks.insert_raw_all/1`'s own binary guard, so any previously
  indexed chunks for it get reconciled away.

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
      # `period: :infinity` with active-only `states` (no :completed) makes an
      # ACTIVE sync the sole one for its source for its whole lifetime — however
      # long it runs — closing the window where a finite period expired while a
      # slow sync was still executing and a second concurrent sync could then
      # regress the cursor / mailbox order. A fresh sync still enqueues once the
      # prior one leaves the active states (completed/discarded/cancelled).
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Chunking
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
        # No newly-resolved issues, but the sync succeeded — refresh
        # last_synced_at (watermark unchanged) so status doesn't read stale.
        mark_synced!(state)
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
          {:ok, _ids} = PendingChunks.insert_raw_all(rows)
          advance_watermark!(state, new_watermark)
          :ok
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
    :ok
  end

  defp raw_row(source, issue) do
    if Chunking.binary_content?(issue.text) do
      deletion_row(source, issue)
    else
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
  end

  defp deletion_row(source, issue) do
    %{
      source: "jira",
      source_id: source.id,
      source_type: "jira_project",
      natural_key: "jira:#{issue.key}",
      metadata: %{"issue_key" => issue.key},
      status: "deleted"
    }
  end

  defp mark_synced!(state) do
    state
    |> SyncState.changeset(%{status: :idle, last_synced_at: DateTime.utc_now()})
    |> Repo.update!()
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
