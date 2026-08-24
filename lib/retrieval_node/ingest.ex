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
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

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
  def force_full_resync_git_sources do
    Source
    |> where([s], s.source_type == :git_repo and s.active == true)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn source, {:ok, count} ->
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
end
