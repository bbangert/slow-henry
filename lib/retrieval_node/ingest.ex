defmodule RetrievalNode.Ingest do
  @moduledoc """
  Ingest context — the source catalog the MCP tool layer reads. The tools call
  `list_repos/0` and `resolve_git_repo/1` here (and `Ingest.GitMirror` for the
  git shell-outs); they never touch `Repo` directly.

  Repo resolution is always against *registered* sources — never a raw directory
  scan — so a caller can only reach mirrors we actually track.
  """
  import Ecto.Query

  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, FileVersion, PendingChunk, Source, SyncState}

  @type repo_entry :: %{
          repo: String.t(),
          source_type: String.t(),
          default_ref: String.t() | nil
        }

  @doc """
  Catalog of active, allow-policy sources as `{repo, source_type, default_ref}`.
  Git sources carry `default_ref: "HEAD"` (the ref `grep`/`get_file` default to);
  non-git sources have no ref.
  """
  @spec list_repos() :: [repo_entry]
  def list_repos do
    Source
    |> where([s], s.active == true and s.policy == :allow)
    |> order_by([s], asc: s.source_type, asc: s.name)
    |> Repo.all()
    |> Enum.map(&entry/1)
  end

  @doc """
  Resolve a caller-supplied repo slug to a registered git source's mirror slug.
  Returns `{:error, :repo_not_found}` when no active git source matches — the tool
  layer surfaces that rather than shelling out against an unknown path.
  """
  @spec resolve_git_repo(String.t()) :: {:ok, String.t()} | {:error, :repo_not_found}
  def resolve_git_repo(repo) when is_binary(repo) do
    git_sources()
    |> Enum.find_value({:error, :repo_not_found}, fn source ->
      slug = Source.mirror_slug(source)
      if slug == repo, do: {:ok, slug}
    end)
  end

  @doc "The git slugs of every active, allow-policy git source (for repo-less grep)."
  @spec git_repo_slugs() :: [String.t()]
  def git_repo_slugs, do: git_sources() |> Enum.map(&Source.mirror_slug/1)

  # Active, allow-policy git sources — the one query resolve_git_repo/git_repo_slugs share.
  defp git_sources do
    Source
    |> where([s], s.source_type == :git_repo and s.active == true and s.policy == :allow)
    |> Repo.all()
  end

  defp entry(%Source{source_type: :git_repo} = s),
    do: %{repo: Source.mirror_slug(s), source_type: "git_repo", default_ref: "HEAD"}

  defp entry(%Source{} = s),
    do: %{repo: s.name, source_type: to_string(s.source_type), default_ref: nil}

  @doc """
  Forces a full re-sync of every active git source by clearing its sync
  watermark (`sync_states.cursor`'s `"last_sha"`) and enqueueing a fresh
  `RepoSync` job. `RepoSync` with no `last_sha` diffs against nothing and
  stages every file in the repo (see its moduledoc); the existing
  `chunk_key`/`content_hash` idempotency in `ChunkFiles`/`UpsertChunks` makes
  the re-run a replace of each chunk, not a duplicate — this is how newly
  added graph extraction (entities/mentions/edges) backfills onto a corpus
  that was already ingested before that pipeline stage existed.

  Only *active* git sources are touched (`policy: :deny` sources are included
  deliberately — `RepoSync` has no policy gate, only `Ingest.list_repos/0`'s
  MCP-facing catalog does); inactive sources and non-git sources are left
  alone entirely.

  `RepoSync` declares a 15-minute `unique` window on `source_id` — if a
  cron-driven `SyncScheduler` tick already queued/started a `RepoSync` for a
  source in that window, `Oban.insert/1` here collapses onto it instead of
  adding a second job. That's fine: the cursor was already cleared before the
  insert, so whichever job actually runs (this one or the cron one it
  deduped onto) does the full re-stage regardless of which caller's args won.
  """
  @spec force_full_resync_git_sources() :: {:ok, non_neg_integer()} | {:error, term()}
  def force_full_resync_git_sources, do: force_full_resync_git_sources(:all)

  @doc """
  Like `force_full_resync_git_sources/0`, but scoped to specific sources —
  `mix rn.graph.backfill --source <name>` targets a re-derive at one or a
  few repos instead of paying the full-corpus re-embed cost (see that task's
  moduledoc). `:all` behaves exactly like the arity-0 function.

  Each entry in `names_or_identifiers` is matched against either a source's
  `name` OR its `identifier` (whichever the caller has handy). Any entry
  that matches no *active* git source is reported back as
  `{:error, {:unknown_sources, unmatched}}` — the whole call is rejected
  (no cursor is cleared, nothing is enqueued) rather than silently
  resyncing a partial set, so a typo'd source name never runs a full
  backfill for the wrong repo without warning.
  """
  @spec force_full_resync_git_sources(:all | [String.t()]) ::
          {:ok, non_neg_integer()}
          | {:error, {:unknown_sources, [String.t()]}}
          | {:error, term()}
  def force_full_resync_git_sources(:all) do
    active_git_sources() |> resync_sources()
  end

  def force_full_resync_git_sources(names_or_identifiers) when is_list(names_or_identifiers) do
    sources = active_git_sources()

    matched =
      Enum.filter(sources, fn s ->
        s.name in names_or_identifiers or s.identifier in names_or_identifiers
      end)

    unknown =
      Enum.reject(names_or_identifiers, fn key ->
        Enum.any?(sources, &(&1.name == key or &1.identifier == key))
      end)

    if unknown == [] do
      resync_sources(matched)
    else
      {:error, {:unknown_sources, unknown}}
    end
  end

  defp active_git_sources do
    Source
    |> where([s], s.source_type == :git_repo and s.active == true)
    |> Repo.all()
  end

  defp resync_sources(sources) do
    Enum.reduce_while(sources, {:ok, 0}, fn source, {:ok, count} ->
      clear_sync_cursor!(source.id)

      case Oban.insert(RepoSync.new(%{"source_id" => source.id})) do
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp clear_sync_cursor!(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state |> SyncState.changeset(%{cursor: %{}}) |> Repo.update!()
    end
  end

  @doc """
  Read-only snapshot of backfill progress: `pending_chunks` counts by stage
  status, `oban_jobs` in-flight counts by queue and state, and corpus-wide
  `graph` totals (entities/entity_mentions/entity_edges plus the chunk count
  they're derived from). Used by `mix rn.graph.backfill --status` to monitor
  a resync started elsewhere (the dev server's Oban queues) without touching
  any state itself.
  """
  @spec backfill_status() :: %{
          pending_chunks: %{String.t() => non_neg_integer()},
          oban_jobs: %{String.t() => %{String.t() => non_neg_integer()}},
          graph: %{
            entities: non_neg_integer(),
            entity_mentions: non_neg_integer(),
            entity_edges: non_neg_integer(),
            chunks: non_neg_integer()
          }
        }
  def backfill_status do
    %{
      pending_chunks: pending_chunk_counts_by_status(),
      oban_jobs: oban_job_counts_by_queue_and_state(),
      graph: graph_totals()
    }
  end

  defp pending_chunk_counts_by_status do
    PendingChunk
    |> group_by([p], p.status)
    |> select([p], {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  @in_flight_states ~w(available scheduled executing retryable)

  defp oban_job_counts_by_queue_and_state do
    Oban.Job
    |> where([j], j.state in @in_flight_states)
    |> group_by([j], [j.queue, j.state])
    |> select([j], {j.queue, j.state, count(j.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {queue, state, count}, acc ->
      Map.update(acc, queue, %{state => count}, &Map.put(&1, state, count))
    end)
  end

  defp graph_totals do
    %{
      entities: Repo.aggregate(Entity, :count, :id),
      entity_mentions: Repo.aggregate(EntityMention, :count, :id),
      entity_edges: Repo.aggregate(EntityEdge, :count, :id),
      chunks: Repo.aggregate(Chunk, :count, :id)
    }
  end

  # --- file-identity chunk reconciliation (shared by UpsertChunks and ChunkFiles) ---

  # Per-source-type identity field a file's chunk rows are grouped/scoped by —
  # the same field each Sync worker's own file-level deletion already keys
  # on: RepoSync.delete_removed/2 -> metadata->>"path", DriveSync.delete_removed/2
  # -> metadata->>"doc_id". JiraSync has no removal path today, but
  # metadata->>"issue_key" is a Jira row's equivalent stable per-issue
  # identity (see JiraSync.raw_row/2). A row whose source_type isn't one of
  # these three, or whose identity field is missing/blank, is skipped —
  # reconciliation never guesses an identity to delete against.
  @identity_metadata_field %{
    "git_repo" => "path",
    "drive_folder" => "doc_id",
    "jira_project" => "issue_key"
  }

  @doc """
  Resolves a file's stable identity `{field, value}` from its `source_type`
  and staged `metadata`, or `nil` when `source_type` isn't a known identity
  carrier or the field is missing/blank. Shared by `reconcile_file_chunks/5`
  and `Ingest.Workers.UpsertChunks`' own batch-grouping (a batch can span more
  than one file — see that module's moduledoc).
  """
  @spec file_identity(String.t(), map() | nil) :: {String.t(), String.t()} | nil
  def file_identity(source_type, metadata) do
    with field when is_binary(field) <- Map.get(@identity_metadata_field, source_type),
         value when is_binary(value) and value != "" <- Map.get(metadata || %{}, field) do
      {field, value}
    else
      _ -> nil
    end
  end

  @doc """
  Deletes every existing `chunks` row for one file (identified by
  `source_type`/`metadata`'s identity field, via `file_identity/2`) whose
  `chunk_key` is NOT in `keep_chunk_keys` — an empty `keep_chunk_keys` deletes
  every chunk row for that file (this is how a file that changes to
  whitespace-only, i.e. produces zero chunks, still sheds its previously
  persisted chunks). FK cascades take care of the orphan's
  `entity_mentions`/`entity_edges` for free once its `chunks` row is gone.

  Runs against `repo` (the caller's transaction/sandbox connection —
  `Ingest.Workers.UpsertChunks` is the pipeline's single terminal stage and
  calls this inside its `Ecto.Multi`, after `claim_file_version/4` has
  confirmed this batch is the file's current version). Returns the number of
  rows deleted; `0` (never an error) when `source_type`/`metadata` resolve no
  identity — reconciliation never guesses an identity to delete against.
  """
  @spec reconcile_file_chunks(Ecto.Repo.t(), binary(), String.t(), map() | nil, [String.t()]) ::
          non_neg_integer()
  def reconcile_file_chunks(repo, source_id, source_type, metadata, keep_chunk_keys) do
    case file_identity(source_type, metadata) do
      nil -> 0
      {field, value} -> delete_stale_chunks(repo, source_id, field, value, keep_chunk_keys)
    end
  end

  @doc """
  SHA-256 hex digest (lowercase) of a file's `identity` — the actual unique
  key `file_versions` claims against (see `claim_file_version/4` and the
  `20260902150001_hash_file_version_identity` migration this backfills from).
  A git path (or any identity) is unbounded text; hashing it down to a fixed
  64-char digest before it ever reaches a B-tree unique index avoids the
  ~2.7 KB index-tuple limit that an unbounded `identity` column could exceed
  — the same failure class as the `entities.qualified_name` incident, where
  every claim for an over-long identity would fail forever (and the terminal
  job would retry into discard).

  MUST stay byte-identical to the migration's SQL backfill —
  `encode(sha256(convert_to(identity, 'UTF8')), 'hex')` — since existing rows'
  `identity_hash` was computed there, not here; `identity` is UTF-8 text on
  both sides, so hashing it as UTF-8 bytes here matches (see the
  `identity_hash/1` test that asserts the two computations agree, via
  `Repo.query!/2`, for both an ASCII and a non-ASCII identity).
  """
  @spec identity_hash(String.t()) :: String.t()
  def identity_hash(identity) when is_binary(identity) do
    :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
  end

  @doc """
  Atomically claims `generation` as the current version of file `identity`
  under `source_id` in `file_versions` — the ingest pipeline's single
  serialization point for per-file invariants (see
  `Ingest.Workers.UpsertChunks`, the pipeline's one terminal stage). One
  statement:

      INSERT INTO file_versions (id, source_id, identity, identity_hash, generation, inserted_at, updated_at)
      VALUES (...)
      ON CONFLICT (source_id, identity_hash) DO UPDATE
        SET generation = EXCLUDED.generation, updated_at = EXCLUDED.updated_at
        WHERE file_versions.generation < EXCLUDED.generation
      RETURNING id

  The unique/conflict key is `(source_id, identity_hash)`, NOT
  `(source_id, identity)` — `identity` is unbounded text (an arbitrary git
  path, Drive doc id, etc.) that could exceed PostgreSQL's ~2.7 KB B-tree
  index-tuple limit and make every claim for that file fail; `identity_hash`
  (see `identity_hash/1`) is a fixed-size digest that can't. `identity` is
  still written on every claim and kept as the human-readable value for
  inspection — nothing reads it as a uniqueness key.

  Postgres takes the conflicting row's lock to evaluate the `ON CONFLICT`
  clause, so two terminal jobs racing for the same `(source_id, identity_hash)`
  serialize right here — the loser blocks on this INSERT until the winner's
  transaction commits, then evaluates the `WHERE` against whatever the
  winner just persisted. Returns `:claimed` (1 row returned) when
  `generation` is strictly newer than what's persisted — including the very
  first claim for a file, since a missing row never blocks the initial
  insert. Returns `:stale` (0 rows) when `generation` is the same (a
  same-version retry after commit — a duplicate delivery of a job whose
  version already landed, correctly a no-op) or older (a genuinely
  out-of-order job that lost the race).

  MUST be called inside the caller's own transaction — the row lock this
  takes is only meaningful held across the reconciliation work it guards;
  claiming outside a transaction (or in one that commits before the guarded
  work runs) defeats the whole point.
  """
  @spec claim_file_version(Ecto.Repo.t(), binary(), String.t(), integer()) :: :claimed | :stale
  def claim_file_version(repo, source_id, identity, generation) do
    now = DateTime.utc_now()

    # The DO UPDATE's WHERE clause compares against EXCLUDED (the row this
    # statement is trying to insert) via fragment, exactly like the on_conflict
    # query form Ecto.Repo.insert_all/3 documents for conditional upserts —
    # confirmed against the actual generated SQL (see the claim_file_version
    # tests' capture_log assertions).
    on_conflict =
      from(f in FileVersion,
        update: [
          set: [
            generation: fragment("EXCLUDED.generation"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ],
        where: fragment("EXCLUDED.generation > ?", f.generation)
      )

    entry = %{
      id: Ecto.UUID.generate(),
      source_id: source_id,
      identity: identity,
      identity_hash: identity_hash(identity),
      generation: generation,
      inserted_at: now,
      updated_at: now
    }

    {count, _} =
      repo.insert_all(FileVersion, [entry],
        on_conflict: on_conflict,
        conflict_target: [:source_id, :identity_hash],
        returning: [:id]
      )

    if count > 0, do: :claimed, else: :stale
  end

  @doc """
  Draws a fresh generation number from the SAME sequence `pending_chunks.id`
  (a bigserial) is drawn from, rather than minting an independent counter.
  Sharing that domain is what makes the draw safely usable as an ingest
  generation for `claim_file_version/4`: every raw staging row already in
  existence at the moment of this call has a strictly smaller id, so a
  generation drawn here outranks any pipeline job staged before this moment —
  including one whose `UpsertChunks` claim hasn't landed yet — while still
  losing to a genuinely later ingest generation (a file re-added after this
  draw stages its own, even later, raw row id and claims with that instead).
  See `Ingest.Workers.RepoSync.delete_removed/2`, today's only caller, for how
  a file deletion uses this to claim a tombstone generation through
  `claim_file_version/4` rather than deleting the `file_versions` row
  outright.

  `nextval` is not transactional — a rolled-back call does not return its
  value to the sequence — which is fine here: the only property this needs
  is monotonicity, not gap-free numbering.
  """
  @spec next_ingest_generation(Ecto.Repo.t()) :: integer()
  def next_ingest_generation(repo) do
    %Postgrex.Result{rows: [[value]]} =
      repo.query!("SELECT nextval(pg_get_serial_sequence('pending_chunks', 'id'))")

    value
  end

  @doc """
  Handles one file's removal as a tombstone claim rather than a guard-row
  delete — the shared protocol behind both `Ingest.Workers.RepoSync.delete_removed/2`
  and `Ingest.Workers.DriveSync.delete_removed/2` (see the former's moduledoc,
  "Deletion is a tombstone claim", for why deleting the `file_versions` row
  outright is unsafe: a still-in-flight pre-deletion terminal job could then
  mistake the row's absence for "no version has ever claimed this identity"
  and resurrect the very chunks this deletion just removed).

  Draws a fresh generation (`next_ingest_generation/1`, from the same
  `pending_chunks.id` sequence a raw row's own generation comes from — see
  that function's @doc for why that ordering guarantee is what makes this
  safe) and claims it for `identity` under `source_id` via
  `claim_file_version/4`. `delete_fun.(repo)` — the caller's own chunk
  deletion, scoped however that source type identifies a file (a git path, a
  Drive doc id, ...) — runs ONLY when the claim wins (`:claimed`); a losing
  claim (`:stale`) means a newer version already committed and this
  deletion must leave its chunks untouched, exactly like `Ingest.Workers.UpsertChunks`'
  own stale-claim skip.

  MUST be called inside the caller's own transaction, same requirement as
  `claim_file_version/4` itself (the row lock the claim takes is only
  meaningful held across `delete_fun`'s work). Always returns `:ok` — the
  claimed-vs-stale branch is fully resolved here, so callers never need to
  inspect it themselves.
  """
  @spec tombstone_file(Ecto.Repo.t(), binary(), String.t(), (Ecto.Repo.t() -> any())) :: :ok
  def tombstone_file(repo, source_id, identity, delete_fun) when is_function(delete_fun, 1) do
    generation = next_ingest_generation(repo)

    case claim_file_version(repo, source_id, identity, generation) do
      :claimed -> delete_fun.(repo)
      # A newer version's terminal job already claimed a higher generation
      # for this identity — its chunks must stay untouched.
      :stale -> :ok
    end

    :ok
  end

  # `metadata->>?` binds the jsonb key as an ordinary text parameter — unlike
  # a column/table name, `->>`'s right-hand side isn't a SQL identifier, so
  # one query shape covers all three known identity fields instead of one
  # hand-written fragment per field name (verified against the generated SQL;
  # this is not the identifier-interpolation footgun it might look like).
  #
  # `chunk_key not in ^keep_chunk_keys` compiles to `NOT (chunk_key = ANY($1))`
  # — the whole key list rides in as ONE array-typed bind parameter, not one
  # bind per key (confirmed via Ecto.Adapters.SQL.to_sql/3), so this is exempt
  # from the 65,535-bind-parameter ceiling that makes UpsertChunks'
  # insert_batches/3 batch its insert_all calls: unlike insert_all, `in`/`not
  # in` against a pinned list never expands into one param per element. An
  # empty `keep_chunk_keys` matches `NOT (chunk_key = ANY('{}'))`, i.e. every
  # row for that identity — deliberate, see `reconcile_file_chunks/5`.
  defp delete_stale_chunks(repo, source_id, field, value, keep_chunk_keys) do
    {count, _} =
      repo.delete_all(
        from(c in Chunk,
          where:
            c.source_id == ^source_id and
              fragment("?->>?", c.metadata, ^field) == ^value and
              c.chunk_key not in ^keep_chunk_keys
        )
      )

    count
  end
end
