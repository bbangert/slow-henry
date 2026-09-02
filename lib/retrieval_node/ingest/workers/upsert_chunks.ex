defmodule RetrievalNode.Ingest.Workers.UpsertChunks do
  @moduledoc """
  The ingest pipeline's ONE terminal stage: idempotently upsert the embedded
  staging rows into the permanent `Retrieval.Chunk` table, then delete the
  consumed `pending_chunks` rows. Every raw row `Ingest.Workers.ChunkFiles` reads
  ends up here — the normal (non-empty) path via `EmbedBatch`, and the zero-chunk
  (e.g. whitespace-only) path directly, with an empty `pending_chunk_ids` and a
  `raw_pending_chunk_id` pointing at the still-present raw row (status
  `"chunked_empty"`). There used to be a second terminal path — `ChunkFiles`
  reconciled a zero-chunk file's stale chunks locally — and every one of that
  design's races got fixed by yet another guard bolted onto one side or the
  other. One path removes the seam those guards were patching over.

  Idempotent via `ON CONFLICT (source_id, chunk_key)` — re-running (a retry, a
  webhook/cron overlap, a re-sync) replaces the row rather than duplicating it.
  The insert + staging cleanup run in one transaction so a crash never leaves the
  chunk written but the staging row lingering (or vice-versa).

  ## The claim: one atomic serialization point per file

  Two versions of one file can be in flight at once — a retried job, an
  hours-deep `:embed` backlog racing a same-file edit that lands later but gets
  processed first — and this worker is unique only by `pending_chunk_ids` (or,
  for the empty case, `raw_pending_chunk_id`), never by file. A per-file
  invariant like "the persisted chunk set is the latest version's set" needs a
  serialization point the pipeline never had; a `max(ingest_generation)` scan
  followed by an upsert is a non-atomic compare-and-set with a window another
  job's terminal stage can land in between the two halves.

  `perform/1` opens its transaction by resolving this batch's file identity and
  generation (from the staged rows themselves, or — for the empty case — from
  the raw row `raw_pending_chunk_id` still points at) and calling
  `Ingest.claim_file_version/4`, an atomic `INSERT ... ON CONFLICT DO UPDATE ...
  WHERE generation < EXCLUDED.generation RETURNING id`. The row lock Postgres
  takes to evaluate that conflict serializes concurrent terminal jobs for the
  same file — the loser blocks on the INSERT until the winner commits, then
  evaluates the WHERE against what the winner just persisted. `:claimed` means
  this batch is now the file's current version — safe to upsert, reconcile, and
  extract graph rows from; `:stale` means a same-or-newer generation already
  landed (including a same-version retry after commit, which correctly no-ops)
  — everything is skipped except staging cleanup. A batch with no resolvable
  identity (an unrecognized `source_type` — see `Ingest.file_identity/2`) skips
  the claim entirely and always proceeds: reconciliation already no-ops without
  an identity to delete against, so there's nothing to serialize, and the
  never-delete-on-a-guess rule holds regardless.

  Also reconciles each file's chunk row set once claimed. `chunk_key` embeds the
  chunk's INDEX (see `ChunkFiles.chunk_key/3`), so a boundary shift earlier in a
  file (a def added/removed) re-keys every chunk after it — the old rows under
  the stale keys would otherwise linger forever (nothing else in the pipeline
  ever revisits a key it stops producing). A file's complete new chunk set
  always arrives in exactly ONE `UpsertChunks` job — `ChunkFiles` reads one raw
  row and produces exactly one downstream batch for it (via `EmbedBatch`, or
  directly for the empty case) — so every staged row in a non-empty batch is
  required to share one file identity; a batch spanning more than one is a bug
  and raises `ArgumentError` (mirroring `Graph.upsert_from_staged/3`'s own
  one-source-per-batch guard) rather than silently partitioning it. Right after
  the upsert, it's safe to delete any existing row for that file whose
  `chunk_key` this batch did NOT reproduce (empty for the zero-chunk case, which
  deletes every existing row) — see `reconcile_file_chunks/5`. FK cascades take
  care of the orphan's `entity_mentions`/`entity_edges` for free once its
  `chunks` row is gone.

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
      keys: [:pending_chunk_ids, :raw_pending_chunk_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias RetrievalNode.Graph
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk}

  # The staged `embedding` is a %Pgvector{} (opaque) that we pass straight into
  # insert_all — correct at runtime (the vector type's dump is a passthrough), but
  # dialyzer sees an opaque term crossing into Ecto.Multi. Silence just that, in
  # every function that builds a Multi over the staged rows (the claim redesign
  # split that construction out of perform/1).
  @dialyzer {:no_opaque,
             [perform: 1, claim_and_process: 5, merge_claim_result: 6, add_cleanup: 3]}

  @replace_on_conflict [
    :content,
    :content_hash,
    :embedding,
    :context_breadcrumb,
    :metadata,
    :parse_status,
    :secrets_status,
    :ingest_generation,
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
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids} = args}) do
    staged_rows = PendingChunks.fetch_many!(ids)
    raw_pending_chunk_id = Map.get(args, "raw_pending_chunk_id")
    now = DateTime.utc_now()

    Ecto.Multi.new()
    |> Ecto.Multi.run(:context, fn repo, _ ->
      {:ok, resolve_context(repo, staged_rows, raw_pending_chunk_id)}
    end)
    |> Ecto.Multi.merge(fn %{context: context} ->
      claim_and_process(context, staged_rows, ids, raw_pending_chunk_id, now)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{reconcile: reconciled}} ->
        if reconciled > 0 do
          Logger.info("upsert_chunks reconciled #{reconciled} stale chunk row(s)")
        end

        :ok

      {:ok, _changes} ->
        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Resolves the batch's file identity/generation. Non-empty batch: from the
  # staged rows themselves (after checking they all agree on one file — see the
  # moduledoc). Empty batch: from the raw row `raw_pending_chunk_id` points at,
  # loaded inside the transaction (it's still present, status `"chunked_empty"`
  # — ChunkFiles' zero-chunk path never reaps it, this worker does). A missing
  # raw row (an idempotent retry after this worker already reaped it) or no
  # `raw_pending_chunk_id` at all resolves to no context — every downstream step
  # then safely no-ops.
  defp resolve_context(_repo, [row | _] = staged_rows, _raw_pending_chunk_id) do
    validate_single_identity!(staged_rows)

    %{
      source_id: row.source_id,
      source_type: row.source_type,
      metadata: row.metadata,
      identity: Ingest.file_identity(row.source_type, row.metadata),
      generation: staged_rows |> Enum.map(&(&1.ingest_generation || 0)) |> Enum.max()
    }
  end

  defp resolve_context(repo, [], raw_pending_chunk_id) when is_integer(raw_pending_chunk_id) do
    case repo.get(PendingChunk, raw_pending_chunk_id) do
      nil ->
        empty_context()

      row ->
        %{
          source_id: row.source_id,
          source_type: row.source_type,
          metadata: row.metadata,
          identity: Ingest.file_identity(row.source_type, row.metadata),
          generation: raw_pending_chunk_id
        }
    end
  end

  defp resolve_context(_repo, [], _raw_pending_chunk_id), do: empty_context()

  defp empty_context,
    do: %{source_id: nil, source_type: nil, metadata: nil, identity: nil, generation: nil}

  # One `ChunkFiles` job's chunks always belong to one file (see the
  # moduledoc) — a batch whose staged rows disagree on (source_id, identity)
  # is a bug upstream, not a shape this worker should silently partition
  # around.
  defp validate_single_identity!(staged_rows) do
    identities =
      staged_rows
      |> Enum.map(&{&1.source_id, Ingest.file_identity(&1.source_type, &1.metadata)})
      |> Enum.uniq()

    case identities do
      [_one] ->
        :ok

      multiple ->
        raise ArgumentError,
              "UpsertChunks requires every staged row in a batch to share one file identity " <>
                "(one ChunkFiles job's chunks always belong to one file) — got #{inspect(multiple)}"
    end
  end

  # No identity to claim/reconcile against (unrecognized source_type, or
  # nothing at all to do — see resolve_context/3) — upsert whatever staged rows
  # there are (possibly none) and clean up. Never guesses an identity to
  # reconcile against, same rule `Ingest.reconcile_file_chunks/5` already
  # enforces on its own.
  defp claim_and_process(%{identity: nil}, staged_rows, ids, raw_pending_chunk_id, now) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:chunks, fn repo, _ ->
      {:ok, insert_batches(repo, Enum.map(staged_rows, &to_chunk_entry/1), now)}
    end)
    |> Ecto.Multi.run(:graph, fn repo, %{chunks: chunk_ids_by_key} ->
      Graph.upsert_from_staged(repo, staged_rows, chunk_ids_by_key)
    end)
    |> add_cleanup(ids, raw_pending_chunk_id)
  end

  defp claim_and_process(%{identity: {_field, value}} = context, staged_rows, ids, rid, now) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:claim, fn repo, _ ->
      {:ok, Ingest.claim_file_version(repo, context.source_id, value, context.generation)}
    end)
    |> Ecto.Multi.merge(fn %{claim: claim} ->
      merge_claim_result(claim, context, staged_rows, ids, rid, now)
    end)
  end

  defp merge_claim_result(:stale, context, _staged_rows, ids, raw_pending_chunk_id, _now) do
    {field, value} = context.identity

    Ecto.Multi.new()
    |> Ecto.Multi.run(:log_stale, fn _repo, _ ->
      Logger.info("skipping stale ingest generation #{context.generation} for #{field}=#{value}")
      {:ok, :logged}
    end)
    |> add_cleanup(ids, raw_pending_chunk_id)
  end

  defp merge_claim_result(:claimed, context, staged_rows, ids, raw_pending_chunk_id, now) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:chunks, fn repo, _ ->
      {:ok, insert_batches(repo, Enum.map(staged_rows, &to_chunk_entry/1), now)}
    end)
    |> Ecto.Multi.run(:reconcile, fn repo, _ ->
      keys = Enum.map(staged_rows, & &1.chunk_key)

      {:ok,
       Ingest.reconcile_file_chunks(
         repo,
         context.source_id,
         context.source_type,
         context.metadata,
         keys
       )}
    end)
    |> Ecto.Multi.run(:graph, fn repo, %{chunks: chunk_ids_by_key} ->
      Graph.upsert_from_staged(repo, staged_rows, chunk_ids_by_key)
    end)
    |> add_cleanup(ids, raw_pending_chunk_id)
  end

  # Deletes the batch's staged chunk rows (`ids`) and, when present, the raw
  # row `raw_pending_chunk_id` points at. The latter is a no-op (0 rows) on the
  # normal path — ChunkFiles already reaped its raw row before EmbedBatch ever
  # ran — and the actual reap for the zero-chunk path, where `ids` is `[]` and
  # this is the only place that raw row gets deleted.
  defp add_cleanup(multi, ids, raw_pending_chunk_id) do
    Ecto.Multi.run(multi, :cleanup, fn repo, _ ->
      {chunk_count, _} = repo.delete_all(PendingChunks.by_ids(ids))

      raw_count =
        case raw_pending_chunk_id do
          nil -> 0
          rid -> repo.delete_all(PendingChunks.by_ids([rid])) |> elem(0)
        end

      {:ok, chunk_count + raw_count}
    end)
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
      # This batch's claimed generation (the raw row's own id) — cheap
      # provenance on the permanent row. NULL for legacy pre-column rows
      # (never produced by the current pipeline).
      ingest_generation: row.ingest_generation,
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
