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
  lifetime `unique` (`period: :infinity`, active states) makes it the sole
  ACTIVE sync for its source, so nothing else could have changed the cursor
  out from under a stale read while this job runs, however long it runs. After
  commit, `Ingest.SourceOwner.notify/1` wakes (or starts) the owner that
  actually applies the batch. Even when `HEAD` is unchanged (`new_sha ==
  last_sha`), `notify/1` still fires — cheap, and it's what lets a previously
  failure-marked row get another look on every cron tick without this job
  needing to know anything about failure state.

  `perform/1` first re-checks `Source.syncable?/1`: a job queued before the
  source was deactivated or denied (or a retry) returns `{:cancel, :ineligible}`
  before touching the mirror, the sync state or the staging table.

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

  ## `args["full"]` — graph backfill

  `"full" => true` (enqueued by `Ingest.force_full_resync_git_sources/0,1`)
  diffs `HEAD` against nil regardless of the stored cursor, so EVERY file in the
  repo is staged, each row tagged `force: true` (re-chunk/re-extract even
  though the content hash is unchanged; `FileIngest` reuses embeddings, so
  this is cheap). The watermark still advances to `HEAD`. A full job never
  short-circuits on `new_sha == last_sha`. The eligibility guard, the
  binary/generated/oversized skip rules and the unreadable-file handling all
  apply unchanged.

  The `unique` above is deliberately NOT keyed on `full`: a full sync is still
  the sole active sync for its source. `force_full_resync_git_sources` therefore
  inserts with `replace: [args: ...]` for the waiting states, upgrading a queued
  plain job to a full one in place; an `executing` job can't be replaced, so
  that source is reported busy and the backfill is re-run once it finishes.
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

  import Ecto.Query, only: [from: 2, subquery: 1, union: 2]

  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Ingest.{GitMirror, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @lang_by_ext %{
    "py" => "python",
    "js" => "javascript",
    "jsx" => "javascript",
    "ts" => "typescript",
    "tsx" => "typescript",
    "go" => "go",
    "rs" => "rust",
    "rb" => "ruby",
    "java" => "java",
    "ex" => "elixir",
    "exs" => "elixir"
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id} = args}) do
    source = Repo.get!(Source, source_id)

    if Source.syncable?(source) do
      sync(source, Map.get(args, "full", false))
    else
      Logger.info("source=#{source.name} not syncable (inactive or denied); cancelling sync")
      {:cancel, :ineligible}
    end
  end

  defp sync(%Source{id: source_id} = source, full?) do
    sync_state = get_or_create_sync_state(source_id)
    slug = repo_slug(source)
    last_sha = unless full?, do: Map.get(sync_state.cursor || %{}, "last_sha")

    with {:ok, _path} <- GitMirror.ensure_mirror(slug, source.identifier),
         {:ok, new_sha} <- GitMirror.head_sha(slug) do
      if new_sha == last_sha do
        # No new commits, but the sync ran successfully — refresh last_synced_at
        # (cursor unchanged) so operational status doesn't read stale/never for a
        # quiet repo. Still notify: the owner may have staged work from a prior
        # run to drain.
        mark_synced!(sync_state)
        SourceOwner.notify(source.id)
        :ok
      else
        sync_changes(source, slug, last_sha, new_sha, sync_state, full?)
      end
    else
      {:error, :empty_repo} ->
        Logger.info("source=#{source.name} repo has no commits yet — nothing to sync")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_changes(source, slug, last_sha, new_sha, sync_state, full?) do
    with {:ok, entries} <- GitMirror.changed_entries(slug, last_sha, new_sha),
         {:ok, rows} <- diff_rows(source, slug, entries, new_sha, full?) do
      stage_and_advance(
        source,
        sync_state,
        new_sha,
        rows,
        reconciler(full?, source, slug, entries)
      )
    end
  end

  defp reconciler(true, source, slug, entries),
    do: fn -> stale_deletion_rows(source, slug, entries) end

  defp reconciler(false, _source, _slug, _entries), do: nil

  # Deletions come from the diff status, NOT from probing `show` — a file that
  # still exists but is unreadable ({:error, :file_too_large}) must be skipped,
  # never mistaken for a deletion and pruned.
  defp diff_rows(source, slug, entries, new_sha, full?) do
    {deleted, present} = Enum.split_with(entries, fn {status, _} -> status == :deleted end)
    deletion_rows = Enum.map(deleted, fn {_status, path} -> deletion_row(source, slug, path) end)

    with {:ok, content_rows} <-
           build_rows(source, slug, Enum.map(present, &elem(&1, 1)), new_sha, full?) do
      {:ok, deletion_rows ++ content_rows}
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
  # this one. The `{:ok, _} =` match makes the atomicity explicit: insert_raw_all
  # returns `{:ok, ids}` or raises (a raise already rolls the outer transaction
  # back), and should its contract ever return `{:error, _}`, the MatchError
  # aborts this transaction too — the watermark can never advance past rows that
  # didn't stage. So the whole thing is atomic: either every row this sync
  # discovered is durable AND the cursor reflects it, or (on any error)
  # neither happened and the next cron tick re-discovers the same diff.
  #
  # `reconcile`, when given, is called inside the transaction and returns extra
  # deletion rows (full mode: see stale_deletion_rows/3).
  defp stage_and_advance(source, sync_state, new_sha, rows, reconcile) do
    {:ok, :ok} =
      Repo.transaction(
        fn ->
          rows = if reconcile, do: reconcile.() ++ rows, else: rows
          if rows != [], do: {:ok, _ids} = PendingChunks.insert_raw_all(rows)
          advance_watermark!(sync_state, new_sha)
          :ok
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
    :ok
  end

  # A full sync diffs HEAD against nothing, so it never sees a file removed
  # since the stored cursor — and advancing the cursor would hide it from every
  # later incremental diff. Instead, stage a deletion entry for every path the
  # source has indexed (applied `chunks`) or staged-but-unapplied (live raw
  # mailbox rows, which a deletion entry supersedes per natural_key) that is
  # absent from HEAD. Both sets come from ONE statement (one snapshot) so the
  # owner moving a row from mailbox to chunks mid-read can't hide a path.
  # Paths present at HEAD are never touched here: skip rules (binary,
  # lockfile, oversized) already stage their own deletion in raw_row/5, so the
  # index follows the current rules; unreadable-but-present files stay as-is.
  defp stale_deletion_rows(source, slug, head_entries) do
    at_head = MapSet.new(head_entries, &elem(&1, 1))

    chunk_paths =
      from c in Chunk,
        where: c.source_id == ^source.id,
        select: %{path: fragment("?->>'path'", c.metadata)}

    pending_paths =
      from p in PendingChunk,
        where: p.source_id == ^source.id and p.status == "raw",
        select: %{path: fragment("?->>'path'", p.metadata)}

    from(u in subquery(union(chunk_paths, ^pending_paths)), select: u.path)
    |> Repo.all()
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(at_head, &1)))
    |> Enum.map(&deletion_row(source, slug, &1))
  end

  defp mark_synced!(sync_state) do
    sync_state
    |> SyncState.changeset(%{status: :idle, last_synced_at: DateTime.utc_now()})
    |> Repo.update!()
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
  defp build_rows(source, slug, paths, new_sha, full?) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case raw_row(source, slug, path, new_sha, full?) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  # Lockfiles, minified bundles and other generated or oversized text add
  # thousands of useless chunks (one yarn.lock is ~550 KB) and monopolise the
  # shared embedding serving. Like binaries, they are staged as deletions so
  # chunks from a previous, smaller version get reconciled away.
  @skip_basenames ~w(yarn.lock package-lock.json pnpm-lock.yaml npm-shrinkwrap.json
                     mix.lock poetry.lock uv.lock Pipfile.lock Cargo.lock go.sum
                     Gemfile.lock composer.lock flake.lock .terraform.lock.hcl)
  @skip_suffixes ~w(.min.js .min.css .map .snap .svg)
  @max_indexed_bytes 256 * 1024

  @doc false
  def indexable?(path, content) do
    base = Path.basename(path)

    byte_size(content) <= @max_indexed_bytes and base not in @skip_basenames and
      not String.ends_with?(base, @skip_suffixes)
  end

  defp raw_row(source, slug, path, new_sha, full?) do
    case GitMirror.show(slug, path, new_sha) do
      {:ok, content} ->
        if Chunking.binary_content?(content) or not indexable?(path, content) do
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
             metadata: %{"path" => path, "ref" => new_sha},
             force: full?
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
