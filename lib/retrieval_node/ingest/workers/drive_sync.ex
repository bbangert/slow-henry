defmodule RetrievalNode.Ingest.Workers.DriveSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Google Drive folder/drive.
  Append-only, same shape as `Ingest.Workers.RepoSync`: fetches Changes since
  the stored `start_page_token`, exports each changed Doc to markdown and
  stages it as a raw `pending_chunks` row, and stages a **deletion entry**
  (`status: "deleted"`, `natural_key: "drive:<doc_id>"`) for each
  removed/unshared doc id — never touches `chunks` directly.
  `Ingest.SourceOwner` is the only process that does (see its moduledoc).

  Staging the rows and advancing the cursor happen in ONE `Repo.transaction`
  (a plain write — this job's `unique` window on `source_id` makes it the
  sole writer of its cursor, so no compare-and-set is needed). After commit,
  `Ingest.SourceOwner.notify/1` wakes (or starts) the owner that applies the
  batch.

  A 429 returns `{:snooze, seconds}`. An export failure stages the
  successes (idempotent via `chunk_key` on the owner's side) but does NOT
  advance the cursor — advancing past a Doc that failed to export would skip
  it forever, since it won't reappear in a later Changes page — and returns
  `{:error, :export_incomplete}` so Oban retries the whole page.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: {30, :minutes},
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.{Drive, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    state = get_or_create_sync_state(source_id)
    cursor = Map.get(state.cursor || %{}, "start_page_token")

    case Drive.fetch_changes(cursor) do
      {:ok, changes} -> ingest(source, state, changes)
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest(source, state, %{changed: changed, removed: removed, cursor: new_cursor}) do
    deletion_rows = Enum.map(removed, &deletion_row(source, &1))
    results = Enum.map(changed, &raw_row(source, &1))
    content_rows = for {:ok, row} <- results, do: row

    stage_and_maybe_advance(source, state, new_cursor, deletion_rows ++ content_rows, results)
  end

  defp deletion_row(source, doc_id) do
    %{
      source: "drive",
      source_id: source.id,
      source_type: "drive_folder",
      natural_key: "drive:#{doc_id}",
      metadata: %{"doc_id" => doc_id},
      status: "deleted"
    }
  end

  defp raw_row(source, doc) do
    case Drive.export_doc(doc.doc_id) do
      {:ok, text} ->
        {:ok,
         %{
           source: "drive",
           source_id: source.id,
           source_type: "drive_folder",
           lang: nil,
           natural_key: "drive:#{doc.doc_id}",
           content_hash: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
           raw_content: text,
           metadata: %{"doc_id" => doc.doc_id, "name" => doc.name}
         }}

      {:error, reason} ->
        {:error, {doc.doc_id, reason}}
    end
  end

  # Advancing the cursor past a Doc we failed to export would skip it forever
  # (it won't reappear in the next Changes page), so the successes are still
  # staged (idempotent via chunk_key on the owner's side) but the cursor is
  # left put and {:error, :export_incomplete} is returned so Oban re-runs the
  # page. Either way, whatever WAS staged is committed and notified — a
  # partial page isn't held back waiting for the whole page to succeed.
  defp stage_and_maybe_advance(source, state, new_cursor, rows, export_results) do
    {:ok, :ok} =
      Repo.transaction(
        fn ->
          if rows != [], do: PendingChunks.insert_raw_all(rows)

          if not Enum.any?(export_results, &match?({:error, _}, &1)),
            do: advance_watermark!(state, new_cursor)

          :ok
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)

    if Enum.any?(export_results, &match?({:error, _}, &1)) do
      {:error, :export_incomplete}
    else
      :ok
    end
  end

  defp advance_watermark!(_state, nil), do: :ok

  defp advance_watermark!(state, cursor) do
    state
    |> SyncState.changeset(%{
      cursor: Map.put(state.cursor || %{}, "start_page_token", cursor),
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
