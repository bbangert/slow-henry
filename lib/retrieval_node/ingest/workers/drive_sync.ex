defmodule RetrievalNode.Ingest.Workers.DriveSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Google Drive folder/drive. Fetches
  Changes since the stored `start_page_token`: each changed Doc is exported to
  markdown, staged as a raw `pending_chunks` row, and enqueued for `ChunkFiles`;
  removed/unshared files have their permanent `chunks` pruned. Advances the cursor.
  A 429 returns `{:snooze, seconds}`.

  ## Deletion is a tombstone claim, not a row delete

  `delete_removed/2` mirrors `Ingest.Workers.RepoSync.delete_removed/2` exactly
  (see that moduledoc's "Deletion is a tombstone claim" section for the full
  race it closes): each removed doc id claims its own fresh generation via
  `Ingest.tombstone_file/4` — the same claim-then-conditionally-delete helper
  RepoSync uses — rather than deleting its `chunks` unconditionally. A
  still-in-flight pre-deletion `UpsertChunks` job for that doc loses the race
  (`:stale`) instead of resurrecting the deleted Doc's chunks, and a deletion
  that runs after a newer version already committed a higher generation loses
  too, leaving that version's chunks untouched. `file_versions` rows are
  therefore never deleted for a Drive source's whole lifetime either — a
  removed doc's row stays as a tombstone recording the highest generation ever
  claimed for it.
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

  alias RetrievalNode.Ingest
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
    Enum.each(doc_ids, &delete_one_doc(source, &1))
    :ok
  end

  # Mirrors RepoSync.delete_one_path/2 — each removed doc id claims its own
  # fresh generation through `Ingest.tombstone_file/4` (draw + claim + the
  # conditional delete all inside one transaction) rather than an
  # unconditional delete. See the moduledoc's "Deletion is a tombstone claim"
  # section.
  defp delete_one_doc(source, doc_id) do
    Repo.transaction(fn ->
      Ingest.tombstone_file(Repo, source.id, doc_id, fn repo ->
        from(c in Chunk,
          where: c.source_id == ^source.id and fragment("?->>'doc_id'", c.metadata) == ^doc_id
        )
        |> repo.delete_all()
      end)
    end)

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
