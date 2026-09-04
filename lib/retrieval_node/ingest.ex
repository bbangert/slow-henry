defmodule RetrievalNode.Ingest do
  @moduledoc """
  Ingest context — the source catalog the MCP tool layer reads. The tools call
  `list_repos/0` and `resolve_git_repo/1` here (and `Ingest.GitMirror` for the
  git shell-outs); they never touch `Repo` directly.

  Repo resolution is always against *registered* sources — never a raw directory
  scan — so a caller can only reach mirrors we actually track.
  """
  import Ecto.Query

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

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
    with field when is_binary(field) <- Map.get(@identity_metadata_field, source_type),
         value when is_binary(value) and value != "" <- Map.get(metadata || %{}, field) do
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
