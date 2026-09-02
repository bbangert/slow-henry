defmodule RetrievalNode.Ingest.Workers.UpsertChunks do
  @moduledoc """
  Terminal ingest stage: idempotently upsert the embedded staging rows into the
  permanent `Retrieval.Chunk` table, then delete the consumed `pending_chunks`.

  Idempotent via `ON CONFLICT (source_id, chunk_key)` — re-running (a retry, a
  webhook/cron overlap, a re-sync) replaces the row rather than duplicating it.
  The insert + staging cleanup run in one transaction so a crash never leaves the
  chunk written but the staging row lingering (or vice-versa).

  Also reconciles each file's chunk row set. `chunk_key` embeds the chunk's
  INDEX (see `ChunkFiles.chunk_key/3`), so a boundary shift earlier in a file
  (a def added/removed) re-keys every chunk after it — the old rows under the
  stale keys would otherwise linger forever (nothing else in the pipeline
  ever revisits a key it stops producing). A file's complete new chunk set
  always arrives in exactly ONE `UpsertChunks` job: `ChunkFiles` reads one
  raw row and enqueues exactly one `EmbedBatch` for the chunk ids it just
  wrote, and `EmbedBatch` enqueues exactly one `UpsertChunks` for that same
  id set (see both workers' `perform/1`). So right after this job's own
  upsert, it's safe to delete any existing row for that file whose
  `chunk_key` this batch did NOT reproduce — see `reconcile_stale_chunks/2`.
  FK cascades take care of the orphan's `entity_mentions`/`entity_edges` for
  free once its `chunks` row is gone.

  Also persists the code-knowledge-graph rows staged on each row's `graph`
  jsonb column (`RetrievalNode.Graph.upsert_from_staged/3`), inside the same
  transaction — the chunk insert's `returning: [:id, :chunk_key]` gives Graph
  the (possibly ON CONFLICT-preserved) chunk ids it needs to link mentions.
  """
  use Oban.Worker,
    queue: :upsert,
    max_attempts: 5,
    unique: [
      period: {30, :minutes},
      keys: [:pending_chunk_ids],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  require Logger

  alias RetrievalNode.Graph
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk

  # The staged `embedding` is a %Pgvector{} (opaque) that we pass straight into
  # insert_all — correct at runtime (the vector type's dump is a passthrough), but
  # dialyzer sees an opaque term crossing into Ecto.Multi. Silence just that.
  @dialyzer {:no_opaque, perform: 1}

  @replace_on_conflict [
    :content,
    :content_hash,
    :embedding,
    :context_breadcrumb,
    :metadata,
    :parse_status,
    :secrets_status,
    :updated_at
  ]

  # Same 65,535-bind-parameter ceiling as PendingChunks.insert_raw_all/1 (see its
  # moduledoc). All ids here come from ONE ChunkFiles job's worth of chunks (a
  # single source file), which is normally small — but a pathological file (many
  # tiny blank-line-delimited chunks, see Chunking.HeuristicImpl) can still push a
  # single file's chunk count into the tens of thousands, so batch defensively
  # too. ~12 params/row here as well → 2,000/batch stays well under the limit.
  @insert_batch_size 2_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids}}) do
    staged_rows = PendingChunks.fetch_many!(ids)
    entries = Enum.map(staged_rows, &to_chunk_entry/1)
    now = DateTime.utc_now()

    Ecto.Multi.new()
    |> Ecto.Multi.run(:chunks, fn repo, _ -> {:ok, insert_batches(repo, entries, now)} end)
    |> Ecto.Multi.run(:reconcile, fn repo, _ ->
      {:ok, reconcile_stale_chunks(repo, staged_rows)}
    end)
    |> Ecto.Multi.run(:graph, fn repo, %{chunks: chunk_ids_by_key} ->
      Graph.upsert_from_staged(repo, staged_rows, chunk_ids_by_key)
    end)
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      {:ok, repo.delete_all(PendingChunks.by_ids(ids))}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{reconcile: reconciled}} ->
        if reconciled > 0 do
          Logger.info("upsert_chunks reconciled #{reconciled} stale chunk row(s)")
        end

        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Batched insert accumulates chunk_key => id across every batch (ON
  # CONFLICT UPDATE still returns rows) — Graph needs this map to link
  # entity_mentions to the chunk rows just written.
  defp insert_batches(repo, entries, now) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.reduce(%{}, fn batch, acc ->
      {_count, rows} =
        repo.insert_all(Chunk, batch,
          placeholders: %{now: now},
          on_conflict: {:replace, @replace_on_conflict},
          conflict_target: [:source_id, :chunk_key],
          returning: [:id, :chunk_key]
        )

      Enum.reduce(rows, acc, fn row, acc -> Map.put(acc, row.chunk_key, row.id) end)
    end)
  end

  defp insert_batch_size,
    do: Application.get_env(:retrieval_node, :upsert_chunks_batch_size, @insert_batch_size)

  # Per-source-type identity field a stale chunk row is grouped/scoped by —
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

  # Deletes, per (source_id, identity) group present in `staged_rows`, every
  # existing `chunks` row for that file whose `chunk_key` this batch did NOT
  # reproduce — see this module's moduledoc for why one batch is always one
  # file's complete new chunk set (grouping below is defense in depth for
  # that assumption, not a reason to trust it blindly: a batch spanning more
  # than one file reconciles each independently rather than cross-deleting).
  defp reconcile_stale_chunks(repo, staged_rows) do
    staged_rows
    |> Enum.group_by(&identity_group/1)
    |> Enum.reduce(0, fn
      {nil, _rows}, deleted ->
        deleted

      {{source_id, field, value}, rows}, deleted ->
        deleted + delete_stale(repo, source_id, field, value, rows)
    end)
  end

  defp identity_group(row) do
    with field when is_binary(field) <- Map.get(@identity_metadata_field, row.source_type),
         value when is_binary(value) and value != "" <- Map.get(row.metadata || %{}, field) do
      {row.source_id, field, value}
    else
      _ -> nil
    end
  end

  # `metadata->>?` binds the jsonb key as an ordinary text parameter — unlike
  # a column/table name, `->>`'s right-hand side isn't a SQL identifier, so
  # one query shape covers all three known identity fields instead of one
  # hand-written fragment per field name (verified against the generated SQL;
  # this is not the identifier-interpolation footgun it might look like).
  #
  # `chunk_key not in ^keys` compiles to `NOT (chunk_key = ANY($1))` — the
  # whole key list rides in as ONE array-typed bind parameter, not one bind
  # per key (confirmed via Ecto.Adapters.SQL.to_sql/3), so this is exempt
  # from the 65,535-bind-parameter ceiling that makes insert_batches/3 above
  # batch its insert_all calls: unlike insert_all, `in`/`not in` against a
  # pinned list never expands into one param per element.
  defp delete_stale(repo, source_id, field, value, rows) do
    keys = Enum.map(rows, & &1.chunk_key)

    {count, _} =
      repo.delete_all(
        from(c in Chunk,
          where:
            c.source_id == ^source_id and
              fragment("?->>?", c.metadata, ^field) == ^value and
              c.chunk_key not in ^keys
        )
      )

    count
  end

  defp to_chunk_entry(row) do
    %{
      source_id: row.source_id,
      # staged enums are strings; insert_all's dump wants the atom.
      source_type: to_enum(:source_type, row.source_type),
      repo: row.repo,
      lang: row.lang,
      chunk_key: row.chunk_key,
      # Chunk.content_hash is the hash of the CHUNK (row.content_hash is the raw-file hash).
      content_hash: sha256(row.chunk_content),
      content: row.chunk_content,
      context_breadcrumb: row.context_breadcrumb,
      metadata: row.metadata,
      embedding: row.embedding,
      parse_status: to_enum(:parse_status, row.parse_status),
      secrets_status: to_enum(:secrets_status, row.secrets_status),
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # Resolve staged enum strings against the Chunk schema's own Ecto.Enum
  # mappings rather than String.to_existing_atom/1: the latter depends on some
  # already-loaded module having interned the atom, which is load-order
  # dependent under the BEAM's lazy (interactive-mode) module loading — e.g.
  # :heuristic_fallback only enters the atom table once a module using it is
  # loaded. Mappings are also a strict allowlist: an unknown string raises
  # instead of resolving to an unrelated pre-existing atom.
  defp to_enum(_field, nil), do: nil
  defp to_enum(_field, value) when is_atom(value), do: value

  defp to_enum(field, value) when is_binary(value) do
    Chunk
    |> Ecto.Enum.mappings(field)
    |> Enum.find(fn {_atom, dump} -> dump == value end)
    |> case do
      {atom, _dump} ->
        atom

      nil ->
        raise ArgumentError,
              "#{inspect(value)} is not a valid dump value for Chunk.#{field} " <>
                "(expected one of #{inspect(Ecto.Enum.dump_values(Chunk, field))})"
    end
  end

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
