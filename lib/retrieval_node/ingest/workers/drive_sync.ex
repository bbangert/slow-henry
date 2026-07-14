defmodule RetrievalNode.Ingest.Workers.DriveSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Google Drive folder/drive. Fetches
  Changes since the stored `start_page_token`: each changed Doc is exported to
  markdown, staged as a raw `pending_chunks` row, and enqueued for `ChunkFiles`;
  removed/unshared files have their permanent `chunks` pruned. Advances the cursor.
  A 429 returns `{:snooze, seconds}`.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: {30, :minutes},
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  alias RetrievalNode.Ingest.{Drive, PendingChunks}
  alias RetrievalNode.Ingest.Workers.ChunkFiles
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source, SyncState}

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
    delete_removed(source, removed)

    results = Enum.map(changed, &raw_row(source, &1))
    rows = for {:ok, row} <- results, do: row
    {:ok, ids} = PendingChunks.insert_raw_all(rows)

    # Advancing the cursor past a Doc we failed to export/enqueue would skip it
    # forever (it won't reappear in the next Changes page). Stage the successes
    # (idempotent via chunk_key), but if any export OR enqueue failed — typically a
    # transient 429/5xx — leave the cursor put and error so Oban re-runs the page.
    with :ok <- enqueue_chunk_files(ids) do
      if Enum.any?(results, &match?({:error, _}, &1)) do
        {:error, :export_incomplete}
      else
        advance_watermark(state, new_cursor)
        :ok
      end
    end
  end

  defp enqueue_chunk_files(ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Oban.insert(ChunkFiles.new(%{"pending_chunk_id" => id})) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp delete_removed(_source, []), do: :ok

  defp delete_removed(source, doc_ids) do
    # One DELETE with an IN over the extracted JSONB doc_id — not one per removal.
    from(c in Chunk,
      where: c.source_id == ^source.id and fragment("?->>'doc_id'", c.metadata) in ^doc_ids
    )
    |> Repo.delete_all()

    :ok
  end

  defp advance_watermark(_state, nil), do: :ok

  defp advance_watermark(state, cursor) do
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
