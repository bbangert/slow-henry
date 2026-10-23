defmodule RetrievalNode.Inventory do
  @moduledoc """
  Read-mostly view of what is indexed, for the LiveView UI: per-source stats,
  the files of a source, the chunks of a file, and the Oban job picture.

  A file is identified the same way `Ingest.file_identity/2` does it:
  `metadata->>'path'` (git), `->>'doc_id'` (Drive) or `->>'issue_key'` (Jira).
  The only write is `enqueue_sync/1`, which inserts the same `*Sync` job the
  cron fan-out (`Ingest.Workers.SyncScheduler`) would.
  """

  import Ecto.Query

  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.Workers.{DriveSync, JiraSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, SecretFinding, Source, SyncState}

  @sync_workers %{git_repo: RepoSync, jira_project: JiraSync, drive_folder: DriveSync}

  defmacrop file_key(metadata) do
    quote do
      fragment(
        "coalesce(?->>'path', ?->>'doc_id', ?->>'issue_key')",
        unquote(metadata),
        unquote(metadata),
        unquote(metadata)
      )
    end
  end

  @doc "All sources with chunk/file/pending/secret counts and their sync state."
  def list_sources do
    chunk_stats =
      from c in Chunk,
        group_by: c.source_id,
        select: %{
          source_id: c.source_id,
          chunks: count(c.id),
          files: count(file_key(c.metadata), :distinct),
          redacted: filter(count(c.id), c.secrets_status == :redacted),
          last_indexed_at: max(c.updated_at)
        }

    pending_stats =
      from p in PendingChunk,
        group_by: p.source_id,
        select: %{
          source_id: p.source_id,
          pending: count(p.id),
          failing: filter(count(p.id), not is_nil(p.last_error))
        }

    finding_stats =
      from f in SecretFinding,
        group_by: f.source_id,
        select: %{source_id: f.source_id, findings: count(f.id)}

    from(s in Source,
      left_join: c in subquery(chunk_stats),
      on: c.source_id == s.id,
      left_join: p in subquery(pending_stats),
      on: p.source_id == s.id,
      left_join: f in subquery(finding_stats),
      on: f.source_id == s.id,
      left_join: st in SyncState,
      on: st.source_id == s.id,
      order_by: [s.source_type, s.name],
      select: %{
        source: s,
        sync: st,
        chunks: coalesce(c.chunks, 0),
        files: coalesce(c.files, 0),
        redacted: coalesce(c.redacted, 0),
        last_indexed_at: c.last_indexed_at,
        pending: coalesce(p.pending, 0),
        failing: coalesce(p.failing, 0),
        findings: coalesce(f.findings, 0)
      }
    )
    |> Repo.all()
  end

  @doc "A source with its sync state, or nil."
  def get_source(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Source{} = source <- Repo.get(Source, uuid) do
      %{source: source, sync: Repo.get_by(SyncState, source_id: uuid)}
    else
      _ -> nil
    end
  end

  @doc """
  Files of a source with their chunk count, optionally filtered by a
  case-insensitive substring of the file key (or Drive doc name).
  """
  def list_files(source_id, filter \\ "") do
    query =
      from c in Chunk,
        where: c.source_id == ^source_id,
        group_by: file_key(c.metadata),
        order_by: file_key(c.metadata),
        select: %{
          key: file_key(c.metadata),
          name: max(fragment("?->>'name'", c.metadata)),
          lang: max(c.lang),
          chunks: count(c.id),
          redacted: filter(count(c.id), c.secrets_status == :redacted),
          fallback: filter(count(c.id), c.parse_status != :ok),
          updated_at: max(c.updated_at)
        }

    query =
      case String.trim(filter) do
        "" ->
          query

        term ->
          like = "%" <> escape_like(term) <> "%"

          where(
            query,
            [c],
            ilike(file_key(c.metadata), ^like) or
              ilike(fragment("?->>'name'", c.metadata), ^like)
          )
      end

    Repo.all(query)
  end

  @doc """
  Chunks of one file of a source, in file order (`metadata.chunk_index`, written
  by `Ingest.FileIngest`; chunks ingested before it existed fall back to
  insertion order). Scoped through `Ingest.file_chunks_query/3` so the lookup
  uses the per-identity `chunks_file_identity_*` indexes.
  """
  def file_chunks(%Source{id: source_id, source_type: source_type}, key) do
    # file_identity/2 picks the field for this source type; offer the key under each.
    identity = Map.new(~w(path doc_id issue_key), &{&1, key})

    case Ingest.file_chunks_query(source_id, to_string(source_type), identity) do
      nil ->
        []

      query ->
        query
        |> order_by([c],
          asc_nulls_last: fragment("(?->>'chunk_index')::int", c.metadata),
          asc: c.inserted_at,
          asc: c.id
        )
        |> Repo.all()
    end
  end

  @doc "Full chunks for the given ids, as a map of id => chunk."
  def chunks_by_id(ids) do
    from(c in Chunk, where: c.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Oban job counts by state and the most recent jobs that hit an error."
  def job_summary(limit \\ 10) do
    counts =
      from(j in Oban.Job, group_by: j.state, select: {j.state, count(j.id)})
      |> Repo.all()
      |> Map.new()

    errored =
      from(j in Oban.Job,
        where: fragment("cardinality(?) > 0", j.errors),
        order_by: [desc: j.attempted_at],
        limit: ^limit
      )
      |> Repo.all()

    %{counts: counts, errored: errored}
  end

  @doc """
  Enqueue a sync for a source, collapsing onto an already queued one.

  Only active sources with `policy: :allow` are synced (the same rule as the
  cron scheduler); any other source returns `{:error, :ineligible}` and no job
  is inserted.
  """
  def enqueue_sync(%Source{active: true, policy: :allow} = source) do
    worker = Map.fetch!(@sync_workers, source.source_type)
    Oban.insert(worker.new(%{"source_id" => source.id}))
  end

  def enqueue_sync(%Source{}), do: {:error, :ineligible}

  defp escape_like(term), do: String.replace(term, ~w(\\ % _), &("\\" <> &1))
end
