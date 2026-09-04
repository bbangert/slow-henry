defmodule RetrievalNode.Ingest.Workers.RepoSync do
  @moduledoc """
  Watermark-driven "discover work" job for a git source. Append-only: ensures
  the bare mirror is current, takes the `diff --raw` (`changed_entries`)
  between the stored `last_sha` and `HEAD`, and stages one `pending_chunks`
  row per changed file — a content row for an added/modified path, a
  **deletion entry** (`status: "deleted"`, no content) for a removed one.
  This job never touches `chunks`: `Ingest.SourceOwner` is the only process
  that does, and it applies these rows in arrival order (see its moduledoc).

  A present file whose new content is binary (`Chunking.binary_content?/1`)
  also stages a deletion entry, keyed on the same identity, instead of a
  content row — `PendingChunks.insert_raw_all/1`'s own binary guard would
  otherwise silently drop it, leaving any previously-indexed chunks for that
  file stuck in the index forever. A deletion entry reconciles them away when
  the owner applies it (a never-indexed binary file then reconciles zero
  rows — harmless).

  Staging the rows and advancing the watermark happen in ONE `Repo.transaction`
  — a plain write (`SyncState.changeset`), not a compare-and-set: this job's
  own `unique` window makes it the sole writer of its source's cursor, so
  nothing else could have changed it out from under a stale read. After
  commit, `Ingest.SourceOwner.notify/1` wakes (or starts) the owner that
  actually applies the batch. Even when `HEAD` is unchanged (`new_sha ==
  last_sha`), `notify/1` still fires — cheap, and it's what lets a previously
  failure-marked row get another look on every cron tick without this job
  needing to know anything about failure state.

  Two edge cases short-circuit before any staging happens:

    * An **empty repo** (no commits) resolves `HEAD` to `{:error, :empty_repo}` —
      logged and completed as a no-op; the watermark stays untouched so the next
      cron tick cheaply re-checks (see `GitMirror.head_sha/2`).
    * A **submodule (gitlink)** entry is filtered out by `GitMirror.changed_entries/3`
      before it ever reaches `show/3`. Defense in depth: if a per-file `show` still
      comes back a deterministic git error (`{:git, _code, _msg}`), that single file
      is skipped-and-logged rather than failing the whole job — a repo-level error
      (mirror missing, timeout) is a different reason and still propagates.

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

  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Ingest.{GitMirror, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

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
        SourceOwner.notify(source.id)
        :ok
      else
        sync_changes(source, slug, last_sha, new_sha, sync_state)
      end
    else
      {:error, :empty_repo} ->
        Logger.info("source=#{source.name} repo has no commits yet — nothing to sync")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_changes(source, slug, last_sha, new_sha, sync_state) do
    with {:ok, entries} <- GitMirror.changed_entries(slug, last_sha, new_sha) do
      # Deletions come from the diff status, NOT from probing `show` — a file that
      # still exists but is unreadable ({:error, :file_too_large}) must be skipped,
      # never mistaken for a deletion and pruned.
      {deleted, present} = Enum.split_with(entries, fn {status, _} -> status == :deleted end)

      deletion_rows =
        Enum.map(deleted, fn {_status, path} -> deletion_row(source, slug, path) end)

      with {:ok, content_rows} <-
             build_rows(source, slug, Enum.map(present, &elem(&1, 1)), new_sha) do
        stage_and_advance(source, sync_state, new_sha, deletion_rows ++ content_rows)
      end
    end
  end

  defp deletion_row(source, slug, path) do
    %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: slug,
      natural_key: "repo:#{source.id}:#{path}",
      metadata: %{"path" => path},
      status: "deleted"
    }
  end

  # Stages this batch's rows AND advances the watermark to new_sha in ONE
  # transaction — insert_raw_all/1's own transaction nests inside (joins)
  # this one, so the whole thing is atomic: either every row this sync
  # discovered is durable AND the cursor reflects it, or (on any error)
  # neither happened and the next cron tick re-discovers the same diff.
  defp stage_and_advance(source, sync_state, new_sha, rows) do
    {:ok, :ok} =
      Repo.transaction(
        fn ->
          if rows != [], do: PendingChunks.insert_raw_all(rows)
          advance_watermark!(sync_state, new_sha)
          :ok
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
    :ok
  end

  defp advance_watermark!(sync_state, new_sha) do
    sync_state
    |> SyncState.changeset(%{
      cursor: Map.put(sync_state.cursor || %{}, "last_sha", new_sha),
      status: :idle,
      last_synced_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  # Build content rows, halting on any *unexpected* show error so the job retries
  # (nothing staged, watermark not advanced) rather than silently dropping the
  # file forever. Known non-indexable/deterministic-per-file cases are skipped
  # instead — the file exists (or, for a gitlink that slipped through, "exists"
  # in a sense `show` can't read), there's nothing a retry would fix.
  defp build_rows(source, slug, paths, new_sha) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case raw_row(source, slug, path, new_sha) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp raw_row(source, slug, path, new_sha) do
    case GitMirror.show(slug, path, new_sha) do
      {:ok, content} ->
        if Chunking.binary_content?(content) do
          # The file is present but its new content can't be staged as text —
          # a deletion entry reconciles away whatever chunks it had under its
          # old (text) content instead of leaving them indexed forever.
          {:ok, deletion_row(source, slug, path)}
        else
          {:ok,
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
           }}
        end

      {:error, :file_too_large} ->
        :skip

      # A deterministic git-level failure on THIS path (e.g. a gitlink/submodule
      # that reached here despite GitMirror's own filtering, or any other object
      # `show` genuinely can't read) — skip just this file, don't fail the job.
      # Distinct from :git_timeout/:git_not_found/:invalid_repo, which are
      # repo-level and still propagate as job errors below.
      {:error, {:git, _code, _msg} = reason} ->
        Logger.warning(
          "skipping unreadable file, not staged: path=#{inspect(path)} reason=#{inspect(reason)}"
        )

        :skip

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_create_sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end

  defp repo_slug(source), do: Source.mirror_slug(source)

  defp lang_for(path) do
    ext = path |> Path.extname() |> String.trim_leading(".")
    Map.get(@lang_by_ext, ext)
  end

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
