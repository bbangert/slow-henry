defmodule RetrievalNode.Ingest.Workers.RepoSync do
  @moduledoc """
  Watermark-driven "discover work" job for a git source. Ensures the bare mirror is
  current, takes the `diff --name-status` (`changed_entries`) between the stored
  `last_sha` and `HEAD`, then for each added/modified file inserts a raw
  `pending_chunks` row and enqueues a `ChunkFiles` job; files the diff marks
  **deleted** have their permanent `chunks` removed. Deletion is decided by the diff
  status, not by whether `show` can read the blob, so an unreadable-but-present file
  is skipped rather than wrongly pruned. The watermark is advanced last (only after
  enqueues succeed), so a crash re-discovers the same work (the `ChunkFiles`/
  `UpsertChunks` idempotency makes re-processing harmless).

  `unique` on `source_id` collapses overlapping cron/webhook triggers for one repo.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: {15, :minutes},
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  alias RetrievalNode.Ingest.{GitMirror, PendingChunks}
  alias RetrievalNode.Ingest.Workers.ChunkFiles
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source, SyncState}

  @lang_by_ext %{
    "py" => "python",
    "js" => "javascript",
    "jsx" => "javascript",
    "ts" => "typescript",
    "tsx" => "typescript",
    "go" => "go",
    "rs" => "rust",
    "rb" => "ruby",
    "java" => "java"
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    sync_state = get_or_create_sync_state(source_id)
    slug = repo_slug(source)
    last_sha = Map.get(sync_state.cursor || %{}, "last_sha")

    with {:ok, _path} <- GitMirror.ensure_mirror(slug, source.identifier),
         {:ok, new_sha} <- GitMirror.head_sha(slug) do
      if new_sha == last_sha do
        :ok
      else
        sync_changes(source, slug, last_sha, new_sha, sync_state)
      end
    end
  end

  defp sync_changes(source, slug, last_sha, new_sha, sync_state) do
    with {:ok, entries} <- GitMirror.changed_entries(slug, last_sha, new_sha) do
      # Deletions come from the diff status, NOT from probing `show` — a file that
      # still exists but is unreadable ({:error, :file_too_large}) must be skipped,
      # never mistaken for a deletion and pruned.
      {deleted, present} = Enum.split_with(entries, fn {status, _} -> status == :deleted end)

      delete_removed(source, Enum.map(deleted, &elem(&1, 1)))

      with :ok <- enqueue_changed(source, slug, Enum.map(present, &elem(&1, 1)), new_sha) do
        advance_watermark(sync_state, new_sha)
        :ok
      end
    end
  end

  defp delete_removed(_source, []), do: :ok

  defp delete_removed(source, paths) do
    Enum.each(paths, fn path ->
      from(c in Chunk,
        where: c.source_id == ^source.id and fragment("?->>'path' = ?", c.metadata, ^path)
      )
      |> Repo.delete_all()
    end)
  end

  defp enqueue_changed(_source, _slug, [], _new_sha), do: :ok

  defp enqueue_changed(source, slug, paths, new_sha) do
    rows = Enum.flat_map(paths, &raw_row(source, slug, &1, new_sha))
    {:ok, ids} = PendingChunks.insert_raw_all(rows)

    # Surface a failed enqueue ({:error, _}) so perform errors and the watermark
    # isn't advanced past staged rows that never got a ChunkFiles job. A unique
    # overlap comes back {:ok, conflict?} and is fine.
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Oban.insert(ChunkFiles.new(%{"pending_chunk_id" => id})) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp raw_row(source, slug, path, new_sha) do
    case GitMirror.show(slug, path, new_sha) do
      {:ok, content} ->
        [
          %{
            source: "git",
            source_id: source.id,
            source_type: "git_repo",
            repo: slug,
            lang: lang_for(path),
            natural_key: "repo:#{source.id}:#{path}",
            content_hash: sha256(content),
            raw_content: content,
            metadata: %{"path" => path, "ref" => new_sha}
          }
        ]

      {:error, _} ->
        []
    end
  end

  defp advance_watermark(sync_state, new_sha) do
    sync_state
    |> SyncState.changeset(%{
      cursor: Map.put(sync_state.cursor || %{}, "last_sha", new_sha),
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

  # Mirror dir slug: explicit config, else the human name.
  defp repo_slug(source), do: Map.get(source.config || %{}, "mirror_slug") || source.name

  defp lang_for(path) do
    ext = path |> Path.extname() |> String.trim_leading(".")
    Map.get(@lang_by_ext, ext)
  end

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
