defmodule RetrievalNode.Ingest.FileIngest do
  @moduledoc """
  The ingest pipeline's functional core: turn one raw `pending_chunks` row into
  the permanent, searchable state for the file it describes — scrub → chunk (+
  extract, one parse) → embed (reusing what hasn't changed) → one write
  transaction (upsert chunks, reconcile the file's chunk set, graph rows, delete
  the raw row). `apply/2` has no process concerns of its own: no queue, no
  retry, no notion of "this source" beyond the one row it's given.

  **Raises on bugs.** Neither write transaction (`reconcile_and_reap/2`,
  `write/7`) catches exceptions — a constraint violation or a
  `Graph.upsert_from_staged/3` raise on malformed staged data rolls the
  transaction back and Ecto re-raises, and that exception is left to
  propagate. This module has no opinion about what a caller should do with a
  bug; `Ingest.SourceOwner` is where that's decided (wrap the call, mark the
  row, keep the queue moving — see its moduledoc) — containing crashes here
  too would just be a second, redundant place that decision could go wrong.

  ## Layering

  This module is the **Functions** layer (per *Designing Elixir Systems with
  OTP*'s Data/Functions/Boundary split): pure-ish (it talks to the DB and the
  embedding/chunking services, but owns no process state and makes no decision
  about *when* or *in what order* to run). The **Boundary** — `Ingest.SourceOwner`,
  a GenServer per source — is what decides ordering: it reads `pending_chunks`
  as its source's FIFO mailbox, collapses to the newest row per file, and calls
  `apply/2` once per row in arrival order.

  **Single-writer by contract**: callers MUST be the owning `Ingest.SourceOwner`.
  Two concurrent callers racing `apply/2` for the same `source_id` (let alone the
  same file) is a bug this module does nothing to prevent — the whole point of
  the owner boundary is that its mailbox is the only serialization point ingest
  needs, so this module doesn't re-derive one (no claim table, no generation
  compare-and-set, no advisory lock). A single-file invariant like "the persisted
  chunk set is this row's set" holds only because exactly one process ever calls
  `apply/2` for a given source at a time.

  ## Contract

  `row` is a `%PendingChunk{}` raw mailbox entry: either `status: "raw"` (file
  content to index) or `status: "deleted"` (a deletion entry — no content, just
  the file's identity). Every successful outcome (`{:ok, _}` or
  `{:skipped, :unchanged}`) DELETES `row` inside the same transaction as its
  writes — the raw row IS the pipeline's only durable "this still needs work"
  marker, so a crash before that delete always leaves something for a retry to
  pick back up, and a crash after it never redoes work under a fresh id.

  `opts`:

    * `:force` (default `row.force`) — re-chunk/re-extract even though the
      file's content hash is unchanged (a graph-only backfill). Embeddings are
      still reused wherever `(chunk_key, content_hash)` matches — see "Embedding
      reuse" below; this is what makes a force re-derive cheap.
    * `:on_parse_crash` (default `:error`) — `:heuristic` on a row's FINAL
      attempt (the caller, `Ingest.SourceOwner`, decides "final" — this module
      has no attempt counter of its own; it replaces the old Oban
      `attempt >= max_attempts` check that lived in the worker).
  """

  import Ecto.Query

  alias RetrievalNode.Chunking
  alias RetrievalNode.Chunking.{Breadcrumb, HeuristicImpl}
  alias RetrievalNode.Embedding
  alias RetrievalNode.Graph
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
    case reconcile_and_reap(row, []) do
      {:ok, reconciled} -> {:ok, %{action: :deleted, reconciled: reconciled}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- 2. unchanged-content skip, then 3. scrub -----------------------------

  def apply(%PendingChunk{} = row, opts) do
    force = Keyword.get(opts, :force, row.force)
    on_parse_crash = Keyword.get(opts, :on_parse_crash, :error)

    if not force and unchanged?(row) do
      PendingChunks.delete_by_ids([row.id])
      {:skipped, :unchanged}
    else
      scrub_and_chunk(row, on_parse_crash)
    end
  end

  # A file whose previous version produced zero chunks has no `chunks` row to
  # match against here — it's simply re-applied (cheap: it'll produce zero
  # chunks again, or the DB will tell us it now produces some).
  defp unchanged?(row) do
    case Ingest.file_identity(row.source_type, row.metadata) do
      nil ->
        false

      {field, value} ->
        Repo.exists?(
          from(c in Chunk,
            where:
              c.source_id == ^row.source_id and
                fragment("?->>?", c.metadata, ^field) == ^value and
                c.file_hash == ^row.content_hash
          )
        )
    end
  end

  # Scrub is a fail-closed pre-step: a `{:cancel, _}` (unredactable secret,
  # too-large, or scanner-unavailable) means the raw row still holds the
  # un-redacted secret it refused to index, so it's treated as unindexable
  # (never leaving plaintext in staging) rather than skipped-and-kept.
  defp scrub_and_chunk(row, on_parse_crash) do
    case Scrubber.scrub(row.raw_content, Map.fetch!(@source_types, row.source)) do
      {:ok, result} ->
        record_audit(row, result.findings)
        # Scrubber returns secrets_status as an atom; the Chunk column is an enum
        # whose dump value is the string form to_enum/2 resolves below.
        opts = [scrub_mode: result.scrub_mode, secrets_status: to_string(result.secrets_status)]
        chunk_and_index(row, result.redacted_content, opts, on_parse_crash)

      {:cancel, reason} ->
        unindexable(row, reason)
    end
  end

  # --- 4. chunk (+ extract) --------------------------------------------------

  defp chunk_and_index(row, content, opts, on_parse_crash) do
    case Chunking.chunk_with_graph(content, row.lang || "") do
      {:ok, %{chunks: chunks, entities: entities, references: references}} ->
        finalize(row, chunks, "ok", opts, entities, references)

      {:error, :unsupported_language} ->
        heuristic_fallback(row, content, "heuristic_fallback", opts)

      {:error, err} when err in [:too_large, :binary_content] ->
        unindexable(row, err)

      {:error, err} ->
        if on_parse_crash == :heuristic do
          heuristic_fallback(row, content, "crashed_fallback", opts)
        else
          {:error, err}
        end
    end
  end

  defp heuristic_fallback(row, content, parse_status, opts) do
    # The heuristic chunker has no AST to walk — no entities/references to attach.
    {:ok, chunks} = HeuristicImpl.chunk(content, row.lang || "")
    finalize(row, chunks, parse_status, opts, [], [])
  end

  # Unindexable content (scrub cancel, oversized, binary) reconciles the
  # file's chunks away with an EMPTY keep-set — the index reflects the current
  # file or nothing — and reaps the raw row (fail-closed: a scrub-cancelled
  # row would otherwise leave un-redacted content sitting in staging forever).
  defp unindexable(row, reason) do
    case reconcile_and_reap(row, []) do
      {:ok, reconciled} -> {:ok, %{action: :unindexable, reason: reason, reconciled: reconciled}}
      {:error, error} -> {:error, error}
    end
  end

  defp reconcile_and_reap(row, keep_chunk_keys) do
    Repo.transaction(fn ->
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

  defp finalize(row, chunks, parse_status, opts, entities, references) do
    graphs = attach_graphs(chunks, entities, references)

    built =
      [chunks, graphs]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map(fn {{chunk, graph}, index} ->
        text = chunk.text

        %{
          chunk_key: chunk_key(row, chunk, index),
          breadcrumb: Breadcrumb.build(file_prefix(row), chunk.breadcrumb),
          text: text,
          # Chunk.content_hash is the hash of the CHUNK (row.content_hash, used
          # as `file_hash` below, is the raw-file hash).
          content_hash: sha256(text),
          graph: graph
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

  # Assigns each entity/reference to the chunk whose start_line..end_line
  # contains its line; items matching no chunk (typically a top-level import
  # sitting between two defs) attach to the FIRST chunk of the file rather
  # than being dropped — imports are file-level signal and losing them would
  # gut the imports leg of the graph. Chunks with no graph items get %{} (the
  # cheapest empty representation for the common case of a prose/no-graph chunk).
  defp attach_graphs(chunks, entities, references) do
    entities_by_chunk =
      Enum.group_by(entities, &chunk_index_for(&1.line, chunks), &entity_attrs/1)

    references_by_chunk =
      Enum.group_by(references, &chunk_index_for(&1.line, chunks), &reference_attrs/1)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {_chunk, index} ->
      graph_attrs(Map.get(entities_by_chunk, index, []), Map.get(references_by_chunk, index, []))
    end)
  end

  defp graph_attrs([], []), do: %{}

  defp graph_attrs(entities, references),
    do: %{"entities" => entities, "references" => references}

  defp chunk_index_for(line, chunks) do
    case Enum.find_index(chunks, &(line >= &1.start_line and line <= &1.end_line)) do
      nil -> 0
      index -> index
    end
  end

  defp entity_attrs(entity),
    do: %{"qualified_name" => entity.qualified_name, "kind" => to_string(entity.kind)}

  defp reference_attrs(ref),
    do: %{"name" => ref.name, "kind" => to_string(ref.kind), "from" => ref.from}

  defp record_audit(_row, []), do: :ok

  defp record_audit(row, findings) do
    Scrubber.record_findings(findings, %{
      source_id: row.source_id,
      file_reference: row.natural_key
    })
  end

  # Embedding reuse: load the file's EXISTING chunks (by file identity, not by
  # this batch's keys — a boundary shift means a chunk at the same ordinal can
  # have a different key than before) and reuse an embedding wherever a new
  # entry's (chunk_key, content_hash) matches an existing row's exactly — same
  # key AND same chunk text means the embedding is still correct. Everything
  # else goes through Embedding.embed_batch/1 in ONE call. Reuse applies
  # unconditionally (force or not) — the model is deterministic, so an
  # unchanged chunk always re-embeds to the same vector; skipping the work
  # instead is what makes a `force: true` graph-only backfill cheap.
  defp embed_with_reuse(row, built) do
    existing = load_existing_chunks(row)

    {reused_entries, to_embed} =
      Enum.split_with(built, fn entry ->
        case Map.get(existing, entry.chunk_key) do
          %{content_hash: hash} -> hash == entry.content_hash
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
    case Ingest.file_identity(row.source_type, row.metadata) do
      nil ->
        %{}

      {field, value} ->
        Chunk
        |> where([c], c.source_id == ^row.source_id)
        |> where([c], fragment("?->>?", c.metadata, ^field) == ^value)
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
  # chunk), graph rows, then the raw row is reaped. Any exception here (an
  # insert constraint violation, a Graph.upsert_from_staged/3 raise on
  # malformed staged data) rolls the transaction back and Ecto re-raises —
  # deliberately NOT caught here (see the moduledoc's "raises on bugs"
  # paragraph): nothing partial is ever left committed, and the raw row
  # survives for a retry either way; `Ingest.SourceOwner` is what turns the
  # exception into a per-row failure mark rather than crashing.
  defp write(row, built, parse_status, opts, embeddings_by_key, embedded, reused) do
    entries = Enum.map(built, &chunk_entry(row, &1, parse_status, opts, embeddings_by_key))
    staged_rows = Enum.map(built, &staged_row(row, &1))
    keep_chunk_keys = Enum.map(built, & &1.chunk_key)

    Repo.transaction(fn ->
      now = DateTime.utc_now()
      chunk_ids_by_key = insert_batches(entries, now)

      reconciled =
        Ingest.reconcile_file_chunks(
          Repo,
          row.source_id,
          row.source_type,
          row.metadata,
          keep_chunk_keys
        )

      {:ok, graph_counts} = Graph.upsert_from_staged(Repo, staged_rows, chunk_ids_by_key)
      PendingChunks.delete_by_ids([row.id])

      %{
        action: :indexed,
        chunks: length(entries),
        reconciled: reconciled,
        embedded: embedded,
        reused: reused,
        graph: graph_counts
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
      # The raw file hash this chunk set was derived from — Ingest.FileIngest's
      # unchanged-content skip reads this back.
      file_hash: row.content_hash,
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # The subset of fields Graph.upsert_from_staged/3 reads off each staged row
  # (source_id, lang, chunk_key, graph — plus metadata/natural_key for its
  # path fallback and log lines). Plain maps, not PendingChunk structs — Graph
  # only ever reads these fields via Map access/dot syntax.
  defp staged_row(row, entry) do
    %{
      source_id: row.source_id,
      lang: row.lang,
      chunk_key: entry.chunk_key,
      graph: entry.graph,
      metadata: row.metadata,
      natural_key: row.natural_key
    }
  end

  # Batched insert accumulates chunk_key => id across every batch (ON
  # CONFLICT UPDATE still returns rows) — Graph needs this map to link
  # entity_mentions to the chunk rows just written. An empty `entries` list
  # (the whitespace-only path) never calls insert_all at all.
  defp insert_batches(entries, now) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.reduce(%{}, fn batch, acc ->
      {_count, rows} =
        Repo.insert_all(Chunk, batch,
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
