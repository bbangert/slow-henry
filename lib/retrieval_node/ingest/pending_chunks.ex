defmodule RetrievalNode.Ingest.PendingChunks do
  @moduledoc """
  Data access for the `pending_chunks` staging table — `Ingest.SourceOwner`'s
  durable per-source mailbox. One of the `Ingest`-context modules allowed to
  touch `Repo`.

  Flow: `*Sync` (`RepoSync`/`DriveSync`/`JiraSync`) `insert_raw_all/1`s a
  content row per changed file (or a deletion entry) and calls
  `Ingest.SourceOwner.notify/1`. The owner reads its source's rows oldest
  first (`drainable/2`), collapsing to the newest per file, and calls
  `Ingest.FileIngest.apply/2` once per kept row — `apply/2` deletes the row on
  every successful outcome (`delete_by_ids/1`); a failing row is left in
  place, marked via `mark_attempt/1`/`mark_failure/3`.
  """

  import Ecto.Query
  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Ingest.SourceOwner
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.PendingChunk

  # A single `insert_all` is capped by Postgres's 65,535-bind-parameter wire
  # protocol limit; each row here binds ~12 params, so one statement tops out
  # around ~5,400 rows. 2,000 rows/batch (~24k params) stays comfortably under
  # that ceiling with room to spare for future columns. Config-overridable (like
  # GitMirror's timeout knobs) purely so tests can exercise the multi-batch path
  # without actually constructing 2,000+ rows.
  @insert_batch_size 2_000

  # An org-scale first sync can stage tens of thousands of full-file rows in
  # one call, all inside the single atomic transaction below — comfortably
  # past Ecto's default 15s connection-checkout timeout even though no single
  # batch is slow. Config-overridable for the same reason as the batch size.
  @insert_timeout :timer.minutes(5)

  @doc """
  Bulk-insert freshly-discovered raw rows, batched under Postgres's 65,535-bind-
  parameter limit (one `insert_all` per `#{@insert_batch_size}`-row batch), all
  inside one transaction so the whole set stays atomic — a failure in any batch
  rolls back everything already inserted this call. Rows come from the internal
  `*Sync` clients; NOT NULL constraints at the DB enforce required fields (a
  malformed row raises → the transaction rolls back → the Oban job retries).

  A row whose `raw_content` is binary (`Chunking.binary_content?/1`) is dropped
  here, before it ever reaches the `text` column — Postgres rejects invalid UTF-8
  outright (error 22021), which would otherwise crash the whole insert (and the
  calling `*Sync` job) over a single bad file. This is the single choke point all
  `*Sync` workers insert through, so the guard applies uniformly without each
  worker re-implementing it, and runs against the FULL row set before batching (a
  batch boundary never splits a file away from its own guard check). Returns
  `{:ok, ids}` for the rows actually inserted, in the same order as `rows`
  (minus skips) — callers that zip ids back against input rows can rely on
  the ordering. Callers then call `Ingest.SourceOwner.notify/1` once for the
  batch's `source_id` — the owner reads these rows itself (`drainable/2`),
  so a skipped row simply never appears there.

  A row may carry `status: "deleted"` — a **deletion entry** for
  `Ingest.FileIngest.apply/2` (no `raw_content`/`content_hash`, just the file's
  identity) — instead of the default `status: "raw"`; the binary-content guard
  above is skipped for it (there's no content to check). A `*Sync` worker whose
  new content for a PRESENT file is binary stages a deletion entry for it
  too (rather than letting this guard silently drop the row) — see each
  worker's moduledoc — so a file that turns binary still reconciles any prior
  chunks away instead of leaving them indexed forever. A row may also carry
  `force: true` (a forced re-derive); both default to their normal values
  (`"raw"`, `false`) when absent, so every existing caller is unaffected.

  An org-scale first sync can push tens of thousands of full-file rows through
  this one atomic transaction, legitimately exceeding Ecto's default 15s
  connection-checkout timeout even though every individual batch is fast — so
  the transaction and each batch's `insert_all` are given the longer,
  config-overridable `@insert_timeout` deadline instead.
  """
  @spec insert_raw_all([map()]) :: {:ok, [integer()]}
  def insert_raw_all(rows) do
    now = DateTime.utc_now()
    {skipped, kept} = Enum.split_with(rows, &binary?/1)

    Enum.each(skipped, &log_skip/1)

    entries = Enum.map(kept, &entry(&1, now))

    Repo.transaction(fn -> insert_batches(entries) end, timeout: insert_timeout())
  end

  defp insert_batches(entries) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.map(fn batch ->
      {_count, rows} =
        Repo.insert_all(PendingChunk, batch, returning: [:id], timeout: insert_timeout())

      Enum.map(rows, & &1.id)
    end)
    |> List.flatten()
  end

  defp insert_batch_size,
    do: Application.get_env(:retrieval_node, :insert_raw_batch_size, @insert_batch_size)

  @doc """
  The timeout `insert_raw_all/1` gives its own transaction/batches. Exposed
  (not `defp`) so a `*Sync` worker can give its OUTER transaction — which
  stages rows via `insert_raw_all/1` (a nested transaction that joins the
  outer one) AND advances the source's sync cursor in the same commit — the
  same deadline, rather than falling back to Ecto's default 15s checkout
  timeout for work that legitimately takes longer on an org-scale first sync.
  """
  @spec insert_timeout() :: pos_integer()
  def insert_timeout,
    do: Application.get_env(:retrieval_node, :insert_raw_timeout, @insert_timeout)

  # A deletion entry has no content to check — and no `raw_content` at all.
  defp binary?(%{status: "deleted"}), do: false
  defp binary?(attrs), do: Chunking.binary_content?(Map.get(attrs, :raw_content) || "")

  defp log_skip(attrs) do
    Logger.info(
      "skipping binary content, not staged: natural_key=#{inspect(Map.get(attrs, :natural_key))}"
    )
  end

  defp entry(attrs, now) do
    # Map.get (not dot access) so a missing key becomes nil → a consistent DB
    # NOT NULL failure, rather than a KeyError before we ever reach the DB.
    %{
      source: Map.get(attrs, :source),
      source_id: Map.get(attrs, :source_id),
      source_type: Map.get(attrs, :source_type),
      repo: Map.get(attrs, :repo),
      lang: Map.get(attrs, :lang),
      natural_key: Map.get(attrs, :natural_key),
      content_hash: Map.get(attrs, :content_hash),
      raw_content: Map.get(attrs, :raw_content),
      metadata: Map.get(attrs, :metadata, %{}),
      status: Map.get(attrs, :status, "raw"),
      force: Map.get(attrs, :force, false),
      inserted_at: now,
      updated_at: now
    }
  end

  @doc "Insert a single raw row, returning the persisted record."
  @spec insert_raw(map()) :: {:ok, PendingChunk.t()} | {:error, Ecto.Changeset.t()}
  def insert_raw(attrs) do
    %PendingChunk{} |> PendingChunk.raw_changeset(attrs) |> Repo.insert()
  end

  @doc "Fetch one staging row by id (raises if missing)."
  @spec fetch!(integer()) :: PendingChunk.t()
  def fetch!(id), do: Repo.get!(PendingChunk, id)

  @doc "Query for the given ids (composable / used for delete)."
  @spec by_ids([integer()]) :: Ecto.Query.t()
  def by_ids(ids), do: from(p in PendingChunk, where: p.id in ^ids)

  @doc "Delete consumed staging rows by id. Returns the count deleted."
  @spec delete_by_ids([integer()]) :: {non_neg_integer(), nil}
  def delete_by_ids(ids), do: Repo.delete_all(by_ids(ids))

  # --- Ingest.SourceOwner's mailbox reads ------------------------------------

  # Truncation ceiling for mark_failure/3's `last_error` — inspect/1 output on
  # a deeply nested reason (a raised struct's full __STACKTRACE__ wrapper) can
  # run to tens of KB; nothing downstream (`--status`, a log line) needs more
  # than a diagnostic-length excerpt.
  @max_error_bytes 2_000

  @doc """
  Rows `Ingest.SourceOwner` can still act on for `source_id`: `status` "raw"
  (content) or "deleted" (a deletion entry), under the max-attempts ceiling
  (`Ingest.SourceOwner.max_file_attempts/0` — the single source of truth
  this and `failed_count/0` both read), and not currently backed off
  (`retry_after` unset or already in the past). Oldest first — the
  bigserial `id` IS arrival order, which is the order the owner applies
  rows in (see `Ingest.SourceOwner`'s moduledoc). `opts[:limit]` bounds one
  drain pass; omitted, every drainable row is returned.
  """
  @spec drainable(binary(), keyword()) :: [PendingChunk.t()]
  def drainable(source_id, opts \\ []) do
    query =
      from(p in PendingChunk,
        where: p.source_id == ^source_id,
        where: p.status in ["raw", "deleted"],
        where: p.attempts < ^SourceOwner.max_file_attempts(),
        where: is_nil(p.retry_after) or p.retry_after <= ^DateTime.utc_now(),
        order_by: [asc: p.id]
      )

    case Keyword.get(opts, :limit) do
      nil -> query
      limit -> limit(query, ^limit)
    end
    |> Repo.all()
  end

  @doc "Whether `source_id` has at least one row `drainable/2` would return — cheaper than fetching one to check."
  @spec drainable?(binary()) :: boolean()
  def drainable?(source_id), do: source_id |> drainable(limit: 1) |> Enum.any?()

  # Reduce a source's mailbox to one row per file — newest id per natural_key
  # (arrival = version order) — in ONE data-modifying statement: a single CTE
  # snapshot both propagates a superseded row's `force` onto the survivor and
  # deletes the superseded rows. Must be one statement (not two under the
  # default READ COMMITTED): if force-propagation and deletion were separate
  # statements, a discovery transaction could commit a newer sibling BETWEEN
  # them — the update would set force on the old survivor, then the delete
  # would see the new row and remove that forced survivor, leaving the new row
  # `force: false` (the very lost-re-derive race this is meant to prevent). In
  # one CTE, `ranked` is computed once; the UPDATE and DELETE both read it, and
  # any row committed after this statement's snapshot is simply left for the
  # next pass's collapse.
  @collapse_sql """
  WITH ranked AS (
    SELECT id, force,
      row_number() OVER (PARTITION BY natural_key ORDER BY id DESC) AS rn,
      bool_or(force) OVER (PARTITION BY natural_key) AS any_force
    FROM pending_chunks
    WHERE source_id = $1::uuid
  ),
  propagated AS (
    UPDATE pending_chunks p SET force = true
    FROM ranked r
    WHERE p.id = r.id AND r.rn = 1 AND r.any_force AND NOT r.force
  ),
  removed AS (
    DELETE FROM pending_chunks p
    USING ranked r
    WHERE p.id = r.id AND r.rn > 1
    RETURNING p.id
  )
  SELECT count(*) FROM removed
  """

  @doc """
  Durably reduce a source's mailbox to one row per file — the newest `id` per
  `natural_key` — carrying any superseded row's `force` onto the survivor and
  deleting the superseded rows, in a single consistent SQL statement (see
  `@collapse_sql`). Returns the number deleted.

  `Ingest.SourceOwner` runs this at the start of every drain pass, so "newest
  per file" holds across the WHOLE source, not just one 50-row drain page (an
  older version in an earlier page would otherwise be fully scrubbed/embedded
  before a newer row is seen), and so the merged `force` survives a crash.
  """
  @spec collapse_source(binary()) :: non_neg_integer()
  def collapse_source(source_id) do
    %Postgrex.Result{rows: [[deleted]]} = Repo.query!(@collapse_sql, [Ecto.UUID.dump!(source_id)])
    deleted
  end

  @doc """
  Distinct `source_id`s with at least one drainable row — `Ingest.SourceOwner.resume_all/0`'s
  boot-time query, so a restart notifies every source that still has staged
  work rather than waiting for that source's next discovery run.
  """
  @spec pending_source_ids() :: [binary()]
  def pending_source_ids do
    max_attempts = SourceOwner.max_file_attempts()

    from(p in PendingChunk,
      where: p.status in ["raw", "deleted"],
      where: p.attempts < ^max_attempts,
      where: is_nil(p.retry_after) or p.retry_after <= ^DateTime.utc_now(),
      distinct: true,
      select: p.source_id
    )
    |> Repo.all()
  end

  @doc """
  Increments `attempts` on one staging row. Called BEFORE `FileIngest.apply/2`
  runs against it (see `Ingest.SourceOwner`'s "one pass" step) so a crash
  mid-apply still counts against the max-attempts ceiling — an `apply/2` that
  never returns can't leave a poison row retried forever. Returns the updated
  row.
  """
  @spec mark_attempt(PendingChunk.t()) :: PendingChunk.t()
  def mark_attempt(%PendingChunk{} = row) do
    # update_all/3's :returning OPTION only applies to the schema-level
    # update/2 — for update_all itself, Ecto only decodes rows back into
    # structs (and Postgres only emits a RETURNING clause) when the QUERY
    # carries its own `select`, so that has to be here, not in opts.
    query = by_ids([row.id]) |> select([p], p)

    {1, [updated]} =
      Repo.update_all(query, inc: [attempts: 1], set: [updated_at: DateTime.utc_now()])

    updated
  end

  @doc """
  Marks a row whose `FileIngest.apply/2` call returned `{:error, reason}`:
  `last_error` (`inspect(reason)`, truncated to #{@max_error_bytes} bytes)
  and `retry_after` so `drainable/2` skips it until the owner's backoff
  window passes. Does not touch `attempts` — `mark_attempt/1` already bumped
  it before the call that produced `reason`.
  """
  @spec mark_failure(PendingChunk.t(), term(), DateTime.t()) :: :ok
  def mark_failure(%PendingChunk{} = row, reason, retry_after) do
    Repo.update_all(by_ids([row.id]),
      set: [
        last_error: reason |> inspect() |> truncate_utf8(@max_error_bytes),
        retry_after: retry_after,
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  defp truncate_utf8(str, max_bytes) when byte_size(str) <= max_bytes, do: str

  defp truncate_utf8(str, max_bytes) do
    candidate = binary_part(str, 0, max_bytes)
    if String.valid?(candidate), do: candidate, else: truncate_utf8(str, max_bytes - 1)
  end

  @doc """
  Count of rows excluded from `drainable/2` by the max-attempts ceiling — a
  file `Ingest.SourceOwner` gave up on.
  """
  @spec failed_count() :: non_neg_integer()
  def failed_count do
    Repo.aggregate(
      from(p in PendingChunk,
        where: p.attempts >= ^SourceOwner.max_file_attempts()
      ),
      :count,
      :id
    )
  end
end
