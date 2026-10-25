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
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

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

  @type resync_summary :: %{
          enqueued: non_neg_integer(),
          upgraded: non_neg_integer(),
          busy: [Source.t()]
        }

  @doc """
  Forces a full re-derive of every active, syncable git source by enqueueing a
  `RepoSync` job with `"full" => true` for each. `RepoSync` diffs against nil
  regardless of the stored cursor (see its moduledoc): it stages every file,
  tagged `force: true`, and still advances the watermark to `HEAD`. This is how
  newly added graph extraction (entities/mentions/edges) backfills onto a corpus
  ingested before it existed; `FileIngest` reuses embeddings wherever
  `(breadcrumb, content_hash)` matches, so the re-derive is cheap.

  Only sources passing `Source.syncable?/1` (active, `policy: :allow`) are
  enqueued; inactive, denied and non-git sources are left alone.

  `RepoSync` is unique per source for its whole active lifetime (sole active sync),
  so a full job can never run alongside a plain one. Each source's outcome
  therefore depends on any conflicting job:

    * `:enqueued` — no active sync existed; a new full job was inserted.
    * `:upgraded` — a plain sync still waiting (`available`/`scheduled`/`retryable`)
      had its args replaced with the full args.
    * `:busy` — a sync is `executing` (or suspended) and cannot be replaced; no
      full job was inserted. Re-running after it finishes enqueues the full sync.
  """
  @spec force_full_resync_git_sources() :: {:ok, resync_summary()} | {:error, term()}
  def force_full_resync_git_sources, do: force_full_resync_git_sources(:all)

  @doc """
  Like `force_full_resync_git_sources/0`, scoped to specific sources. Each entry
  is matched against a syncable git source's `name` OR `identifier`; any entry
  that matches none is reported as `{:error, {:unknown_sources, unmatched}}` and
  nothing is enqueued, so a typo never resyncs a partial set.
  """
  @spec force_full_resync_git_sources(:all | [String.t()]) ::
          {:ok, resync_summary()} | {:error, {:unknown_sources, [String.t()]}} | {:error, term()}
  def force_full_resync_git_sources(:all), do: resync_sources(syncable_git_sources())

  def force_full_resync_git_sources(names_or_identifiers) when is_list(names_or_identifiers) do
    sources = syncable_git_sources()

    matched =
      Enum.filter(
        sources,
        &(&1.name in names_or_identifiers or &1.identifier in names_or_identifiers)
      )

    unknown =
      Enum.reject(names_or_identifiers, fn key ->
        Enum.any?(sources, &(&1.name == key or &1.identifier == key))
      end)

    if unknown == [], do: resync_sources(matched), else: {:error, {:unknown_sources, unknown}}
  end

  defp syncable_git_sources do
    Source
    |> where([s], s.source_type == :git_repo and s.active == true and s.policy == :allow)
    |> Repo.all()
  end

  @waiting_states ~w(available scheduled retryable)

  # `replace: [args: ...]` for the waiting states only: a conflicting job that
  # is still queued is upgraded in place (Oban returns it with `conflict?`),
  # while one already executing keeps its args and is reported busy.
  defp resync_sources(sources) do
    Enum.reduce_while(sources, {:ok, %{enqueued: 0, upgraded: 0, busy: []}}, fn source,
                                                                                {:ok, acc} ->
      job =
        RepoSync.new(%{"source_id" => source.id, "full" => true},
          replace: Enum.map(@waiting_states, &{String.to_existing_atom(&1), [:args]})
        )

      case Oban.insert(job) do
        {:ok, %Oban.Job{conflict?: false}} ->
          {:cont, {:ok, Map.update!(acc, :enqueued, &(&1 + 1))}}

        {:ok, %Oban.Job{state: state}} when state in @waiting_states ->
          {:cont, {:ok, Map.update!(acc, :upgraded, &(&1 + 1))}}

        {:ok, %Oban.Job{}} ->
          {:cont, {:ok, Map.update!(acc, :busy, &(&1 ++ [source]))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Read-only snapshot of backfill progress: `pending_chunks` counts by status,
  in-flight `oban_jobs` counts by queue and state, corpus-wide `graph` totals,
  `failed_files` (`PendingChunks.failed_count/0`) and `owners` (how many
  `SourceOwner` processes are registered on THIS VM — 0 on a short-lived admin
  task's own boot). Used by `mix rn.graph.backfill --status`.
  """
  @spec backfill_status() :: %{
          pending_chunks: %{atom() => non_neg_integer()},
          oban_jobs: %{String.t() => %{String.t() => non_neg_integer()}},
          graph: %{atom() => non_neg_integer()},
          failed_files: non_neg_integer(),
          owners: non_neg_integer()
        }
  def backfill_status do
    %{
      pending_chunks: pending_chunk_counts_by_status(),
      oban_jobs: oban_job_counts_by_queue_and_state(),
      graph: graph_totals(),
      failed_files: PendingChunks.failed_count(),
      owners: Registry.count(RetrievalNode.Ingest.SourceRegistry)
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

  # --- file-identity chunk reconciliation ---

  # Per-source-type identity field a file's chunk rows are grouped/scoped by —
  # the same field each Sync worker's own file-level deletion already keys
  # on: RepoSync.delete_removed/2 -> metadata->>"path", DriveSync.delete_removed/2
  # -> metadata->>"doc_id". JiraSync has no removal path today, but
  # metadata->>"issue_key" is a Jira row's equivalent stable per-issue
  # identity. A row whose source_type isn't one of these three, or whose
  # identity field is missing/blank, is skipped — reconciliation never
  # guesses an identity to delete against.
  @identity_metadata_field %{
    "git_repo" => "path",
    "drive_folder" => "doc_id",
    "jira_project" => "issue_key"
  }

  @doc """
  Resolves a file's stable identity `{field, value}` from its `source_type`
  and staged `metadata`, or `nil` when `source_type` isn't a known identity
  carrier or the field is missing/blank. `field` is one of the LITERAL jsonb
  keys `"path"` / `"doc_id"` / `"issue_key"` (never caller-supplied), which is
  what lets `file_chunks_query/3` emit a literal-key `->>` the expression
  indexes can use.
  """
  @spec file_identity(String.t(), map() | nil) :: {String.t(), String.t()} | nil
  def file_identity(source_type, metadata) do
    # A whitespace-only value is treated as blank: it matches no real chunk's
    # identity, so accepting it would let a deletion reconcile zero rows, reap
    # its tombstone, and report success while the old chunks stay indexed. The
    # value returned for matching is the original (untrimmed) — a legitimate
    # identity keeps its exact text.
    with field when is_binary(field) <- Map.get(@identity_metadata_field, source_type),
         value when is_binary(value) <- Map.get(metadata || %{}, field),
         true <- String.trim(value) != "" do
      {field, value}
    else
      _ -> nil
    end
  end

  @doc """
  Builds an `Ecto.Query` selecting every `chunks` row for ONE file — scoped by
  `source_id` plus the file's identity (`file_identity/2`) — or `nil` when the
  row carries no resolvable identity. `Ingest.FileIngest` layers `select`/
  `exists?`/`delete_all` on top for its unchanged-content skip, embedding-reuse
  load, and chunk-set reconciliation, so all three share one indexable shape.

  The identity predicate is emitted with a LITERAL jsonb key per source type
  (`metadata->>'path'`, not `metadata->>$n`): a parameterized key can't use an
  expression index, so the literal is what makes the
  `chunks_file_identity_*_idx` indexes (see the staging migration) actually
  fire instead of a per-source seq scan. The key is never caller-supplied — it
  comes only from the fixed `@identity_metadata_field` allowlist.
  """
  @spec file_chunks_query(binary(), String.t(), map() | nil) :: Ecto.Query.t() | nil
  def file_chunks_query(source_id, source_type, metadata) do
    case file_identity(source_type, metadata) do
      nil ->
        nil

      {field, value} ->
        scope_by_identity(from(c in Chunk, where: c.source_id == ^source_id), field, value)
    end
  end

  defp scope_by_identity(query, "path", value),
    do: where(query, [c], fragment("?->>'path'", c.metadata) == ^value)

  defp scope_by_identity(query, "doc_id", value),
    do: where(query, [c], fragment("?->>'doc_id'", c.metadata) == ^value)

  defp scope_by_identity(query, "issue_key", value),
    do: where(query, [c], fragment("?->>'issue_key'", c.metadata) == ^value)

  @doc """
  Deletes every existing `chunks` row for one file (identified by
  `source_type`/`metadata`'s identity field, via `file_identity/2`) whose
  `chunk_key` is NOT in `keep_chunk_keys` — an empty `keep_chunk_keys` deletes
  every chunk row for that file (this is how a file that changes to
  whitespace-only, i.e. produces zero chunks, still sheds its previously
  persisted chunks). FK cascades take care of the orphan's dependent rows for
  free once its `chunks` row is gone.

  Runs against `repo` (the caller's transaction/sandbox connection —
  `Ingest.FileIngest.apply/2` calls this inside its own write transaction).
  Returns the number of rows deleted; `0` (never an error) when
  `source_type`/`metadata` resolve no identity — reconciliation never
  guesses an identity to delete against.
  """
  @spec reconcile_file_chunks(Ecto.Repo.t(), binary(), String.t(), map() | nil, [String.t()]) ::
          non_neg_integer()
  def reconcile_file_chunks(repo, source_id, source_type, metadata, keep_chunk_keys) do
    case file_chunks_query(source_id, source_type, metadata) do
      nil ->
        0

      query ->
        # `chunk_key not in ^keep_chunk_keys` compiles to `NOT (chunk_key =
        # ANY($1))` — the whole key list rides in as ONE array-typed bind
        # parameter, so this is exempt from the 65,535-bind ceiling that
        # batches bulk inserts. An empty `keep_chunk_keys` matches every row
        # for the identity (deletes the file's whole chunk set) — deliberate.
        {count, _} = repo.delete_all(where(query, [c], c.chunk_key not in ^keep_chunk_keys))
        count
    end
  end
end
