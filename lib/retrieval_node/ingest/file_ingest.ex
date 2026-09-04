defmodule RetrievalNode.Ingest.FileIngest do
  @moduledoc """
  The ingest pipeline's functional core: turn one raw `pending_chunks` row into
  the permanent, searchable state for the file it describes — scrub → chunk
  (one parse) → embed (reusing what hasn't changed) → one write transaction
  (upsert chunks, reconcile the file's chunk set, delete the raw row).
  `apply/2` has no process concerns of its own: no queue, no retry, no notion
  of "this source" beyond the one row it's given.

  **Raises on bugs.** The write transaction (`reconcile_and_reap/3`, `write/7`)
  does not catch exceptions — a constraint violation rolls the transaction
  back and Ecto re-raises, and that exception is left to propagate. This
  module has no opinion about what a caller should do with a bug; deciding
  that (wrap the call, mark the row, keep the queue moving) is the job of
  whatever boundary process ends up calling `apply/2` in production — no such
  process exists on this branch yet.

  **Single-writer by contract**: callers MUST serialize calls to `apply/2` per
  `source_id` (and, within a source, per file) — two concurrent callers racing
  the same file is a bug this module does nothing to prevent. It has no claim
  table, no generation compare-and-set, no advisory lock; a single-file
  invariant like "the persisted chunk set is this row's set" only holds when
  exactly one process ever applies rows for a given source at a time.

  ## Contract

  `row` is a `%PendingChunk{}` raw mailbox entry: either `status: "raw"` (file
  content to index) or `status: "deleted"` (a deletion entry — no content, just
  the file's identity). Every successful outcome (`{:ok, _}` or
  `{:skipped, :unchanged}`) DELETES `row` inside the same transaction as its
  writes — the raw row IS the pipeline's only durable "this still needs work"
  marker, so a crash before that delete always leaves something for a retry to
  pick back up, and a crash after it never redoes work under a fresh id.

  `opts`:

    * `:force` (default `row.force`) — re-chunk even though the file's content
      hash is unchanged. Embeddings are still reused wherever
      `(chunk_key, content_hash)` matches — see "Embedding reuse" below.
    * `:on_parse_crash` (default `:error`) — `:heuristic` on a row's FINAL
      attempt (the caller decides "final"; this module has no attempt
      counter of its own).
  """

  import Ecto.Query

  alias RetrievalNode.Chunking
  alias RetrievalNode.Chunking.{Breadcrumb, HeuristicImpl}
  alias RetrievalNode.Embedding
  alias RetrievalNode.Ingest
  alias RetrievalNode.Ingest.{PendingChunks, Scrubber}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk}

  @type summary :: %{required(:action) => atom(), optional(atom()) => term()}

  @source_types %{"git" => :git_repo, "jira" => :jira_project, "drive" => :drive_folder}

  # Same 65,535-bind-parameter ceiling as PendingChunks.insert_raw_all/1 (see
  # its moduledoc) — every insert_all below batches at this size. All ids
  # here come from ONE row's worth of chunks (a single file), which is
  # normally small, but a pathological file (many tiny blank-line-delimited
  # chunks — see Chunking.HeuristicImpl) can still push a single file's
  # chunk count into the tens of thousands, so batch defensively too.
  @insert_batch_size 2_000

  @replace_on_conflict [
    :content,
    :content_hash,
    :embedding,
    :context_breadcrumb,
    :metadata,
    :parse_status,
    :secrets_status,
    :file_hash,
    :updated_at
  ]

  @spec apply(PendingChunk.t(), keyword()) ::
          {:ok, summary} | {:skipped, :unchanged} | {:error, term()}
  def apply(row, opts \\ [])

  # --- 1. deletion entry ----------------------------------------------------

  def apply(%PendingChunk{status: "deleted"} = row, _opts) do
    # A deletion whose identity can't be resolved has no chunks it could
    # reconcile away — reaping its row anyway would report success while the
    # old chunks stay indexed forever. Reject it instead, so the row survives
    # for diagnosis/retry rather than vanishing.
    if resolvable_identity?(row) do
      case reconcile_and_reap(row, [], []) do
        {:ok, reconciled} -> {:ok, %{action: :deleted, reconciled: reconciled}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_file_identity}
    end
  end

  # --- 2. unchanged-content skip, then 3. scrub -----------------------------

  def apply(%PendingChunk{} = row, opts) do
    force = Keyword.get(opts, :force, row.force)
    on_parse_crash = Keyword.get(opts, :on_parse_crash, :error)

    cond do
      # Same guard as the deletion path: a content row we can't identify can't
      # have its stale chunks reconciled, so refuse it rather than write an
      # unreconcilable file. (Not reachable for a well-formed *Sync row, which
      # always carries a path/doc_id/issue_key — it's a fail-closed backstop.)
      not resolvable_identity?(row) ->
        {:error, :no_file_identity}

      not force and unchanged?(row) ->
        PendingChunks.delete_by_ids([row.id])
        {:skipped, :unchanged}

      true ->
        scrub_and_chunk(row, on_parse_crash)
    end
  end

  defp resolvable_identity?(row),
    do: not is_nil(Ingest.file_identity(row.source_type, row.metadata))

  # A file whose previous version produced zero chunks has no `chunks` row to
  # match against here — it's simply re-applied (cheap: it'll produce zero
  # chunks again, or the DB will tell us it now produces some).
  defp unchanged?(row) do
    case Ingest.file_chunks_query(row.source_id, row.source_type, row.metadata) do
      nil -> false
      query -> Repo.exists?(where(query, [c], c.file_hash == ^row.content_hash))
    end
  end

  # Scrub is a fail-closed pre-step: a `{:cancel, _}` (unredactable secret,
  # too-large, or scanner-unavailable) means the raw row still holds the
  # un-redacted secret it refused to index, so it's treated as unindexable
  # (never leaving plaintext in staging) rather than skipped-and-kept.
  defp scrub_and_chunk(row, on_parse_crash) do
    case Scrubber.scrub(row.raw_content, Map.fetch!(@source_types, row.source)) do
      {:ok, result} ->
        # Scrubber returns secrets_status as an atom; the Chunk column is an enum
        # whose dump value is the string form to_enum/2 resolves below.
        # `secrets_status` lands on each chunk row; `findings` are recorded INSIDE
        # the terminal transaction (see `record_audit/2`) so the audit rows commit
        # atomically with the row's deletion and never survive a failed/retried
        # ingest. `result.scrub_mode` is dropped: nothing downstream reads it.
        opts = [secrets_status: to_string(result.secrets_status), findings: result.findings]
        chunk_and_index(row, result.redacted_content, opts, on_parse_crash)

      {:cancel, reason} ->
        # A cancel produced no redacted result, so there are no findings to log.
        unindexable(row, reason, [])
    end
  end

  # --- 4. chunk ---------------------------------------------------------

  defp chunk_and_index(row, content, opts, on_parse_crash) do
    case Chunking.chunk(content, row.lang || "") do
      {:ok, chunks} ->
        finalize(row, chunks, "ok", opts)

      {:error, :unsupported_language} ->
        heuristic_fallback(row, content, "heuristic_fallback", opts)

      {:error, err} when err in [:too_large, :binary_content] ->
        unindexable(row, err, Keyword.get(opts, :findings, []))

      {:error, err} ->
        if on_parse_crash == :heuristic do
          heuristic_fallback(row, content, "crashed_fallback", opts)
        else
          {:error, err}
        end
    end
  end

  defp heuristic_fallback(row, content, parse_status, opts) do
    {:ok, chunks} = HeuristicImpl.chunk(content, row.lang || "")
    finalize(row, chunks, parse_status, opts)
  end

  # Unindexable content (scrub cancel, oversized, binary) reconciles the
  # file's chunks away with an EMPTY keep-set — the index reflects the current
  # file or nothing — and reaps the raw row (fail-closed: a scrub-cancelled
  # row would otherwise leave un-redacted content sitting in staging forever).
  defp unindexable(row, reason, findings) do
    case reconcile_and_reap(row, [], findings) do
      {:ok, reconciled} -> {:ok, %{action: :unindexable, reason: reason, reconciled: reconciled}}
      {:error, error} -> {:error, error}
    end
  end

  defp reconcile_and_reap(row, keep_chunk_keys, findings) do
    Repo.transaction(fn ->
      record_audit(row, findings)

      reconciled =
        Ingest.reconcile_file_chunks(
          Repo,
          row.source_id,
          row.source_type,
          row.metadata,
          keep_chunk_keys
        )

      PendingChunks.delete_by_ids([row.id])
      reconciled
    end)
  end

  # --- 5. build chunk entries, 6. embed with reuse, 7. write -----------------

  defp finalize(row, chunks, parse_status, opts) do
    built =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        text = chunk.text

        %{
          chunk_key: chunk_key(row, chunk, index),
          breadcrumb: Breadcrumb.build(file_prefix(row), chunk.breadcrumb),
          text: text,
          # Chunk.content_hash is the hash of the CHUNK (row.content_hash, used
          # as `file_hash` below, is the raw-file hash).
          content_hash: sha256(text)
        }
      end)

    {embeddings_by_key, embedded, reused} = embed_with_reuse(row, built)
    write(row, built, parse_status, opts, embeddings_by_key, embedded, reused)
  end

  # chunk_key = sha256 over the natural key + chunk ordinal + symbol trail — a
  # stable identity so re-ingesting the same file upserts (not duplicates).
  # It embeds the chunk's INDEX, so a boundary shift earlier in a file (a def
  # added/removed) re-keys every chunk after it — reconcile_file_chunks below
  # is what sheds the old rows under the stale keys once this batch commits.
  defp chunk_key(row, chunk, index) do
    :crypto.hash(:sha256, "#{row.natural_key}|#{index}|#{chunk.breadcrumb}")
    |> Base.encode16(case: :lower)
  end

  defp file_prefix(row), do: Map.get(row.metadata || %{}, "path") || row.natural_key

  # Called only from inside a terminal `Repo.transaction` (`write/7`,
  # `reconcile_and_reap/3`), so the append-only audit rows commit exactly when
  # the file's ingest does — a failed/retried ingest never leaves orphan or
  # duplicate findings. A record failure rolls the whole transaction back (the
  # raw row survives for retry) instead of being silently dropped.
  defp record_audit(_row, []), do: :ok

  defp record_audit(row, findings) do
    case Scrubber.record_findings(findings, %{
           source_id: row.source_id,
           file_reference: row.natural_key
         }) do
      {:ok, _count} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # Embedding reuse: load the file's EXISTING chunks (by file identity, not by
  # this batch's keys — a boundary shift means a chunk at the same ordinal can
  # have a different key than before) and reuse an embedding wherever a new
  # entry's (chunk_key, content_hash) matches an existing row's exactly — same
  # key AND same chunk text means the embedding is still correct. Everything
  # else goes through Embedding.embed_batch/1 in ONE call. Reuse applies
  # unconditionally (force or not) — the model is deterministic, so an
  # unchanged chunk always re-embeds to the same vector; skipping the work
  # instead is what makes a `force: true` re-derive cheap.
  defp embed_with_reuse(row, built) do
    existing = load_existing_chunks(row)

    {reused_entries, to_embed} =
      Enum.split_with(built, fn entry ->
        case Map.get(existing, entry.chunk_key) do
          # Reuse only when the text is unchanged AND the stored row actually
          # HAS an embedding — Chunk.embedding is nullable, and reusing a nil
          # would persist an unembedded chunk and skip embedding it.
          %{content_hash: hash, embedding: emb} -> hash == entry.content_hash and not is_nil(emb)
          nil -> false
        end
      end)

    texts = Enum.map(to_embed, &embed_text/1)
    vectors = if texts == [], do: [], else: Embedding.embed_batch(texts)

    # Fail loud rather than let Enum.zip silently drop the tail if the serving
    # ever returns fewer vectors than texts — a truncated zip would strand
    # those chunks unembedded with no error surfaced.
    if length(vectors) != length(to_embed) do
      raise "embed_batch returned #{length(vectors)} vectors for #{length(to_embed)} chunk(s)"
    end

    fresh_by_key =
      to_embed
      |> Enum.zip(vectors)
      |> Map.new(fn {entry, vector} -> {entry.chunk_key, Pgvector.new(vector)} end)

    reused_by_key =
      Map.new(reused_entries, fn entry ->
        {entry.chunk_key, Map.fetch!(existing, entry.chunk_key).embedding}
      end)

    {Map.merge(fresh_by_key, reused_by_key), length(to_embed), length(reused_entries)}
  end

  defp load_existing_chunks(row) do
    case Ingest.file_chunks_query(row.source_id, row.source_type, row.metadata) do
      nil ->
        %{}

      query ->
        query
        |> select([c], {c.chunk_key, %{content_hash: c.content_hash, embedding: c.embedding}})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp embed_text(%{breadcrumb: crumb, text: text}) when crumb in [nil, ""], do: text
  defp embed_text(%{breadcrumb: crumb, text: text}), do: Breadcrumb.prepend(crumb, text)

  # One transaction: batched insert into Chunk (ON CONFLICT replace — the same
  # identity, chunk_key, upserts rather than duplicating), reconcile the
  # file's chunk set (deletes any existing row for this file whose key isn't
  # in this batch — empty for a whitespace-only file, which sheds every prior
  # chunk), then the raw row is reaped. Any exception here (an insert
  # constraint violation) rolls the transaction back and Ecto re-raises —
  # deliberately NOT caught here (see the moduledoc's "raises on bugs"
  # paragraph): nothing partial is ever left committed, and the raw row
  # survives for a retry either way.
  defp write(row, built, parse_status, opts, embeddings_by_key, embedded, reused) do
    entries = Enum.map(built, &chunk_entry(row, &1, parse_status, opts, embeddings_by_key))
    keep_chunk_keys = Enum.map(built, & &1.chunk_key)

    Repo.transaction(fn ->
      record_audit(row, Keyword.get(opts, :findings, []))
      now = DateTime.utc_now()
      insert_batches(entries, now)

      reconciled =
        Ingest.reconcile_file_chunks(
          Repo,
          row.source_id,
          row.source_type,
          row.metadata,
          keep_chunk_keys
        )

      PendingChunks.delete_by_ids([row.id])

      %{
        action: :indexed,
        chunks: length(entries),
        reconciled: reconciled,
        embedded: embedded,
        reused: reused
      }
    end)
  end

  defp chunk_entry(row, entry, parse_status, opts, embeddings_by_key) do
    %{
      source_id: row.source_id,
      # row.source_type is a string; insert_all's dump wants the atom.
      source_type: to_enum(:source_type, row.source_type),
      repo: row.repo,
      lang: row.lang,
      chunk_key: entry.chunk_key,
      content_hash: entry.content_hash,
      content: entry.text,
      context_breadcrumb: entry.breadcrumb,
      metadata: row.metadata,
      embedding: Map.fetch!(embeddings_by_key, entry.chunk_key),
      parse_status: to_enum(:parse_status, parse_status),
      secrets_status: to_enum(:secrets_status, opts[:secrets_status]),
      # The raw file hash this chunk set was derived from — FileIngest's
      # unchanged-content skip reads this back.
      file_hash: row.content_hash,
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # Batched upsert (ON CONFLICT on the chunk identity replaces the row). An
  # empty `entries` list (the whitespace-only path) never calls insert_all.
  defp insert_batches(entries, now) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.each(fn batch ->
      Repo.insert_all(Chunk, batch,
        placeholders: %{now: now},
        on_conflict: {:replace, @replace_on_conflict},
        conflict_target: [:source_id, :chunk_key]
      )
    end)
  end

  defp insert_batch_size,
    do: Application.get_env(:retrieval_node, :upsert_chunks_batch_size, @insert_batch_size)

  # Resolve enum strings against the Chunk schema's own Ecto.Enum mappings
  # rather than String.to_existing_atom/1: the latter depends on some
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
