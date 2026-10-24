defmodule RetrievalNode.Graph do
  @moduledoc """
  Owns the write path for the code-knowledge-graph tables (`entities`,
  `entity_mentions`, `entity_edges`). Touches `Repo` directly — like `Bench`
  and the `Ingest` context modules, a deliberate exception to the
  one-context-per-table boundary: this module IS the context responsible for
  those three tables, not a call-site reaching around one.

  `upsert_from_staged/3` takes the output of `RetrievalNode.Graph.Extractor`
  (in-memory, atom-keyed) attached to the chunk rows a caller just wrote, and
  is meant to run inside that caller's write transaction. It assumes all
  staged rows come from one source file (hence one `source_id`), so a source's
  single writer never races another caller for the same entities.

  The read side of these tables (entity lookup, caller/callee traversal,
  definition snippets) lands in a later change.
  """

  import Ecto.Query

  require Logger

  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Repo

  # Same 65,535-bind-parameter ceiling as PendingChunks/FileIngest (see
  # PendingChunks' moduledoc) — every insert_all below batches at this size.
  @insert_batch_size 2_000

  # Default batch for gc_orphaned_entities/1 — see its own docs for why this
  # is batched at all.
  @gc_batch_size 10_000

  @type counts :: %{
          entities: non_neg_integer(),
          mentions: non_neg_integer(),
          edges: non_neg_integer()
        }

  @doc """
  Upsert entities/mentions/edges derived from each staged row's `graph` into
  the permanent graph tables. Returns counts for logging.

  `staged_rows` is a list of maps (or structs) with:

    * `:source_id` - the owning source; must be identical across the batch
    * `:lang` - the file's language string; every row that carries graph data
      must share one (rows with no graph data may be `nil`)
    * `:chunk_key` - looked up in `chunk_ids_by_key` to find the persisted
      chunk id; rows with no entry there are skipped
    * `:graph` - `nil`, `%{}`, or `%{entities: [...], references: [...]}` in
      `RetrievalNode.Graph.Extractor`'s native shape (atom keys, atom kinds:
      entity `kind` in `:function | :method | :class | :module`, reference
      `kind` in `:call | :import`). Either key may be absent. Malformed or
      oversized (> #{256} bytes) entries are dropped with a warning
    * `:metadata` - string-keyed map; `"path"` becomes the entity's `path`
      (nil is fine)
    * `:natural_key` - fallback `path` when `metadata` has no `"path"`

  Definitions duplicated within the batch (e.g. each clause of a multi-clause
  Elixir function) collapse to one entity before the insert.
  """
  @type staged_row :: %{
          required(:source_id) => Ecto.UUID.t(),
          required(:lang) => String.t() | nil,
          required(:chunk_key) => String.t(),
          required(:graph) => map() | nil,
          required(:metadata) => map() | nil,
          required(:natural_key) => String.t(),
          optional(atom()) => term()
        }

  @spec upsert_from_staged(Ecto.Repo.t(), [staged_row()], %{String.t() => Ecto.UUID.t()}) ::
          {:ok, counts}
  def upsert_from_staged(_repo, [], _chunk_ids_by_key),
    do: {:ok, %{entities: 0, mentions: 0, edges: 0}}

  def upsert_from_staged(repo, staged_rows, chunk_ids_by_key) do
    now = DateTime.utc_now()
    staged_rows = Enum.map(staged_rows, &sanitize_graph/1)
    source_id = staged_rows |> hd() |> Map.fetch!(:source_id)

    # write_edges/2's per-from-entity delete-then-rederive safety argument
    # assumes every row in this batch belongs to one source (one file) —
    # FileIngest batches are per-file today; this pins that assumption so a
    # future caller violating it fails loudly instead of silently clobbering
    # another file's edges.
    unless Enum.all?(staged_rows, &(Map.fetch!(&1, :source_id) == source_id)) do
      raise ArgumentError,
            "upsert_from_staged/3 requires every staged row to share one source_id"
    end

    # Entity identity is (source_id, language, qualified_name) —
    # resolve_entity_ids/4's select-back must filter on language too, or a
    # symbol defined under the same qualified_name in two languages of one
    # source (e.g. "setup" in both a Python and a JS file) would collide and
    # bind mentions/edges to the wrong-language row. Batches are per-file, so
    # every row that actually carries graph data shares one language; rows
    # with lang: nil (heuristic-chunked files) never carry graph data (only
    # tree-sitter emits graph), so this only raises when graph-bearing rows
    # themselves disagree — a mixed/nil-lang batch with no graph data at all
    # passes through as language: nil without raising.
    language = resolve_batch_language(staged_rows)

    def_entities = collect_definitions(staged_rows)
    def_keys = MapSet.new(def_entities, &{&1.source_id, &1.language, &1.qualified_name})
    ref_entities = collect_reference_entities(staged_rows, def_keys)

    entities_written = upsert_definitions(repo, def_entities, now)
    ref_entities_written = upsert_reference_entities(repo, ref_entities, now)

    entity_ids = resolve_entity_ids(repo, source_id, language, def_entities ++ ref_entities)

    chunk_ids = touched_chunk_ids(staged_rows, chunk_ids_by_key)
    delete_stale_mentions(repo, chunk_ids)
    mentions_written = insert_mentions(repo, staged_rows, chunk_ids_by_key, entity_ids, now)

    edges_written =
      upsert_edges(repo, staged_rows, chunk_ids_by_key, chunk_ids, entity_ids, def_entities, now)

    {:ok,
     %{
       entities: entities_written + ref_entities_written,
       mentions: mentions_written,
       edges: edges_written
     }}
  end

  # --- garbage collection -------------------------------------------------

  @doc """
  Deletes entities with zero remaining `entity_mentions` — a file's chunks
  going away (a deletion entry, or a boundary shift that reconciles old
  `chunk_key`s out — see `Ingest.FileIngest`) cascades away the mentions on
  those chunks but has no reason to know about the entities they used to
  point at, so a zero-mention entity is a durable orphan until something
  reaps it. Its `entity_edges` rows die for free via their own `entities` FK
  cascade — no separate edge cleanup needed here. Chunk-provenance edge rows
  (those carrying a non-NULL `chunk_id`) additionally cascade the moment
  their owning chunk is deleted, via `entity_edges.chunk_id`'s own FK — same
  lifecycle as `entity_mentions` — so this GC's job for those rows is
  already partly done by the time an entity goes zero-mention; the
  `entities` FK cascade above remains the catch-all for whatever a chunk
  deletion didn't reach (e.g. legacy NULL-`chunk_id` edge rows).

  `:source_id` scopes the candidate select to one source; omitted, it scans
  every source.

  Deletes in batches of `:batch_size` (default 10,000) rather than one
  statement: `entities` is sized for a many-repo corpus (can reach into the
  millions of rows), and one unbounded `DELETE` would hold its row locks
  and accumulate undo/WAL for the entire scan instead of releasing them
  between batches. Loops until a round's candidate select comes back
  shorter than a full batch. Returns the total number of entities deleted.
  Raises `ArgumentError` if `:batch_size` is not a positive integer — a
  non-positive batch never returns fewer candidates than itself, which
  would otherwise recurse forever on an empty batch.

  No locking: with a single writer per source (`Ingest.SourceOwner`), no
  concurrent process can land a new mention on a candidate between the select
  and the delete, so each batch is a plain "select candidate ids, delete
  those ids" inside one transaction.
  """
  @spec gc_orphaned_entities(keyword()) :: non_neg_integer()
  def gc_orphaned_entities(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @gc_batch_size)
    validate_positive_batch_size!(batch_size)
    source_id = Keyword.get(opts, :source_id)
    gc_batches(batch_size, source_id, 0)
  end

  # Shared entry-point guard for every batch_size this module uses to drive a
  # batching loop, whether it arrives via a caller's opts
  # (gc_orphaned_entities/1) or via Application config (insert_batch_size/0):
  # a non-positive value can never advance such a loop correctly. For
  # gc_batches/2, batch_size <= 0 makes the candidate SELECT's `limit`
  # return [] every round, so `candidate_count < batch_size` (0 < 0, or
  # anything < a negative) is always false and the loop recurses on the same
  # empty batch forever. For insert_all_batched/4's
  # `Enum.chunk_every(entries, batch_size)`, a non-positive batch_size raises
  # FunctionClauseError instead of hanging — still worth rejecting here, at
  # the point the value enters the module, so the failure is a clear
  # ArgumentError rather than an opaque clause-mismatch deep in Enum.
  defp validate_positive_batch_size!(n) when is_integer(n) and n > 0, do: :ok

  defp validate_positive_batch_size!(other) do
    raise ArgumentError, "batch_size must be a positive integer, got: #{inspect(other)}"
  end

  defp gc_batches(batch_size, source_id, total) do
    {candidate_count, deleted} = delete_orphaned_batch(batch_size, source_id)
    total = total + deleted

    if candidate_count < batch_size do
      total
    else
      gc_batches(batch_size, source_id, total)
    end
  end

  # One transaction: select this round's candidate ids, delete them. No
  # locking — a single writer per source (Ingest.SourceOwner) means no
  # concurrent process can land a new mention on a candidate between the
  # SELECT and the DELETE, so unlike an earlier multi-writer revision of
  # this function, there's no snapshot race here to guard against. The
  # candidate count (not the delete count — the two are always equal now)
  # drives gc_batches/3's "was that a full batch" decision.
  defp delete_orphaned_batch(batch_size, source_id) do
    {:ok, {candidate_count, deleted}} =
      Repo.transaction(fn ->
        orphan_ids =
          orphan_candidates_query(source_id)
          |> select([e], e.id)
          |> limit(^batch_size)
          |> Repo.all()

        {count, _} = Repo.delete_all(from(e in Entity, where: e.id in ^orphan_ids))

        {length(orphan_ids), count}
      end)

    {candidate_count, deleted}
  end

  defp orphan_candidates_query(source_id) do
    from(e in Entity,
      as: :entity,
      where:
        not exists(
          from(m in EntityMention, where: m.entity_id == parent_as(:entity).id, select: 1)
        )
    )
    |> scope_source(source_id)
  end

  defp scope_source(query, nil), do: query
  defp scope_source(query, source_id), do: from(e in query, where: e.source_id == ^source_id)

  # --- staged-graph sanitation --------------------------------------------

  # Defensive filter over each row's graph: malformed or oversized symbols are
  # dropped with a warning instead of raising inside the caller's write
  # transaction, where one junk symbol would roll back every real chunk in the
  # file. An oversized name additionally risks the entities unique btree
  # index's ~2,700-byte row limit. Mirrors Extractor.TreeSitter's
  # @max_symbol_bytes emission cap.
  #
  # Validated at two levels: the `:entities`/`:references` containers must be
  # lists (a non-list counts as one dropped container), and each element must
  # be a map with a binary name (<= @max_symbol_bytes) and an atom kind. An
  # element surviving this is safe for the Map.fetch!/kind conversions below;
  # an unknown-but-atom kind still raises downstream, deliberately.
  @max_symbol_bytes 256

  defp sanitize_graph(%{graph: graph} = row) when graph == %{} or is_nil(graph),
    do: %{row | graph: %{}}

  defp sanitize_graph(%{graph: graph} = row) when is_map(graph) do
    {kept_entities, entities_dropped} =
      graph |> Map.get(:entities, []) |> filter_symbols(:qualified_name)

    {kept_references, references_dropped} =
      graph |> Map.get(:references, []) |> filter_symbols(:name)

    dropped = entities_dropped + references_dropped

    if dropped > 0 do
      Logger.warning(
        "dropping #{dropped} invalid or oversized graph symbol(s) " <>
          "(non-list container, malformed shape, or > #{@max_symbol_bytes} bytes) " <>
          "from natural_key=#{inspect(row.natural_key)}"
      )
    end

    %{row | graph: %{entities: kept_entities, references: kept_references}}
  end

  # A non-map graph is one dropped container.
  defp sanitize_graph(row) do
    Logger.warning("dropping non-map graph from natural_key=#{inspect(row.natural_key)}")
    %{row | graph: %{}}
  end

  defp filter_symbols(list, key) when is_list(list) do
    kept = Enum.filter(list, &valid_symbol?(&1, key))
    {kept, length(list) - length(kept)}
  end

  defp filter_symbols(_not_a_list, _key), do: {[], 1}

  defp valid_symbol?(el, key) when is_map(el) do
    with name when is_binary(name) <- Map.get(el, key),
         true <- byte_size(name) <= @max_symbol_bytes,
         kind when is_atom(kind) and not is_nil(kind) <- Map.get(el, :kind) do
      true
    else
      _ -> false
    end
  end

  defp valid_symbol?(_el, _key), do: false

  # --- definitions -----------------------------------------------------

  defp collect_definitions(staged_rows) do
    staged_rows
    |> Enum.flat_map(fn row ->
      row.graph
      |> Map.get(:entities, [])
      |> Enum.map(&definition_attrs(row, &1))
    end)
    # Dedup by the conflict key BEFORE the insert: the extractor emits one
    # entity per clause of a multi-clause Elixir function (and per Python
    # overload), and a repeated key inside a single ON CONFLICT DO UPDATE
    # insert makes Postgres raise. Last write wins.
    |> Enum.reduce(%{}, fn attrs, acc ->
      Map.put(acc, {attrs.source_id, attrs.language, attrs.qualified_name}, attrs)
    end)
    |> Map.values()
  end

  defp definition_attrs(row, entity) do
    %{
      source_id: row.source_id,
      language: row.lang,
      qualified_name: Map.fetch!(entity, :qualified_name),
      kind: entity_kind(Map.fetch!(entity, :kind)),
      path: Map.get(row.metadata || %{}, "path") || row.natural_key
    }
  end

  defp upsert_definitions(_repo, [], _now), do: 0

  defp upsert_definitions(repo, def_entities, now) do
    entries =
      def_entities
      |> Enum.map(&entity_entry/1)
      |> sort_by_conflict_key(&{&1.source_id, &1.language, &1.qualified_name})

    insert_all_batched(repo, Entity, entries,
      placeholders: %{now: now},
      on_conflict: {:replace, [:kind, :path, :updated_at]},
      conflict_target: [:source_id, :language, :qualified_name]
    )
  end

  # --- reference-only entities ------------------------------------------

  defp collect_reference_entities(staged_rows, def_keys) do
    staged_rows
    |> Enum.flat_map(fn row ->
      row.graph
      |> Map.get(:references, [])
      |> Enum.map(&reference_entity_attrs(row, &1))
    end)
    |> Enum.reject(&MapSet.member?(def_keys, {&1.source_id, &1.language, &1.qualified_name}))
    |> Enum.reduce(%{}, fn attrs, acc ->
      Map.put_new(acc, {attrs.source_id, attrs.language, attrs.qualified_name}, attrs)
    end)
    |> Map.values()
  end

  defp reference_entity_attrs(row, ref) do
    %{
      source_id: row.source_id,
      language: row.lang,
      qualified_name: Map.fetch!(ref, :name),
      kind: ref_entity_kind(Map.fetch!(ref, :kind)),
      path: nil
    }
  end

  defp ref_entity_kind(:call), do: :function
  defp ref_entity_kind(:import), do: :module

  # A future producer (e.g. an LLM extractor) could emit a ref kind neither
  # clause expects. Fail with a clear ArgumentError here rather than a
  # FunctionClauseError deep inside the caller's write transaction.
  defp ref_entity_kind(other) do
    raise ArgumentError,
          "unknown reference kind #{inspect(other)} — expected :call or :import"
  end

  defp upsert_reference_entities(_repo, [], _now), do: 0

  defp upsert_reference_entities(repo, ref_entities, now) do
    entries =
      ref_entities
      |> Enum.map(&entity_entry/1)
      |> sort_by_conflict_key(&{&1.source_id, &1.language, &1.qualified_name})

    # on_conflict: :nothing — a reference is only a guess that some entity
    # exists. An existing definition (upserted above, or from an earlier
    # ingest) must never be clobbered by a bare call/import sighting.
    insert_all_batched(repo, Entity, entries,
      placeholders: %{now: now},
      on_conflict: :nothing,
      conflict_target: [:source_id, :language, :qualified_name]
    )
  end

  defp entity_entry(attrs) do
    %{
      source_id: attrs.source_id,
      language: attrs.language,
      qualified_name: attrs.qualified_name,
      kind: attrs.kind,
      path: attrs.path,
      metadata: %{},
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # --- id resolution -----------------------------------------------------

  # Rows that carry no entities/references contribute nothing to
  # collect_definitions/collect_reference_entities and must not force the
  # batch language check below to consider them.
  defp graph_data?(%{graph: graph}) do
    Map.get(graph, :entities, []) != [] or Map.get(graph, :references, []) != []
  end

  defp resolve_batch_language(staged_rows) do
    staged_rows
    |> Enum.filter(&graph_data?/1)
    |> Enum.map(& &1.lang)
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      [language] ->
        language

      _ ->
        raise ArgumentError,
              "upsert_from_staged/3 requires every staged row with graph data to share one language"
    end
  end

  defp resolve_entity_ids(_repo, _source_id, _language, []), do: %{}

  defp resolve_entity_ids(repo, source_id, language, entities) do
    names = entities |> Enum.map(& &1.qualified_name) |> Enum.uniq()

    # on_conflict: :nothing doesn't return the ids of rows that hit the
    # conflict path, so ids for BOTH definitions and reference-only entities
    # are resolved here with one explicit select-back instead. `in ^names`
    # compiles to a single array-bound parameter (unlike insert_all's
    # per-row binds), so this needs no batching regardless of name count.
    #
    # language is filtered here (not just source_id) because entity identity
    # is (source_id, language, qualified_name) — without this filter, a
    # same-named symbol defined in two languages of one source would return
    # both rows and the Map.new/1 below would let one silently overwrite the
    # other's id, binding mentions/edges to the wrong-language entity.
    query =
      from e in Entity,
        where:
          e.source_id == ^source_id and e.language == ^language and e.qualified_name in ^names,
        select: {e.qualified_name, e.id}

    query |> repo.all() |> Map.new()
  end

  # --- mentions ------------------------------------------------------------

  defp touched_chunk_ids(staged_rows, chunk_ids_by_key) do
    staged_rows
    |> Enum.map(&Map.get(chunk_ids_by_key, &1.chunk_key))
    |> Enum.reject(&is_nil/1)
  end

  defp delete_stale_mentions(_repo, []), do: 0

  defp delete_stale_mentions(repo, chunk_ids) do
    # A re-chunked file whose new version dropped a call must not keep the
    # old mention. The chunk row's id survives ON CONFLICT UPDATE (same
    # chunk_key), so the entity_mentions FK cascade never fires for a
    # replacement — mentions are instead fully re-derived on every ingest of
    # this batch's chunks.
    {count, _} = repo.delete_all(from(m in EntityMention, where: m.chunk_id in ^chunk_ids))
    count
  end

  defp insert_mentions(repo, staged_rows, chunk_ids_by_key, entity_ids, now) do
    entries =
      staged_rows
      |> Enum.flat_map(&mention_entries(&1, chunk_ids_by_key, entity_ids))
      |> sort_by_conflict_key(&{&1.entity_id, &1.chunk_id, &1.kind})

    insert_all_batched(repo, EntityMention, entries,
      placeholders: %{now: now},
      on_conflict: :nothing,
      conflict_target: [:entity_id, :chunk_id, :kind]
    )
  end

  # Rows whose chunk_key has no entry in chunk_ids_by_key were skipped by
  # FileIngest's own insert (shouldn't happen in practice — every staged row
  # in this job was just written — but skip rather than crash on a nil chunk id).
  defp mention_entries(row, chunk_ids_by_key, entity_ids) do
    case Map.get(chunk_ids_by_key, row.chunk_key) do
      nil ->
        []

      chunk_id ->
        definition_mentions(row, chunk_id, entity_ids) ++
          reference_mentions(row, chunk_id, entity_ids)
    end
  end

  defp definition_mentions(row, chunk_id, entity_ids) do
    row.graph
    |> Map.get(:entities, [])
    |> Enum.map(&entity_ids[Map.fetch!(&1, :qualified_name)])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&mention_entry(&1, chunk_id, :definition))
  end

  defp reference_mentions(row, chunk_id, entity_ids) do
    row.graph
    |> Map.get(:references, [])
    |> Enum.map(fn ref ->
      {entity_ids[Map.fetch!(ref, :name)], mention_kind(Map.fetch!(ref, :kind))}
    end)
    |> Enum.reject(fn {entity_id, _kind} -> is_nil(entity_id) end)
    |> Enum.map(fn {entity_id, kind} -> mention_entry(entity_id, chunk_id, kind) end)
  end

  defp mention_kind(:call), do: :call
  defp mention_kind(:import), do: :import

  # Same rationale as ref_entity_kind/1's catch-all — fail clearly on an
  # extractor-seam value neither clause expects, instead of crashing with a
  # FunctionClauseError.
  defp mention_kind(other) do
    raise ArgumentError,
          "unknown mention kind #{inspect(other)} — expected :call or :import"
  end

  defp mention_entry(entity_id, chunk_id, kind) do
    %{
      entity_id: entity_id,
      chunk_id: chunk_id,
      kind: kind,
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  # --- edges -----------------------------------------------------------

  # Aggregated per (chunk_id, source_entity_id, target_entity_id, kind) — NOT
  # collapsed across the whole batch — because the chunk is the edge's
  # provenance (see EntityEdge's moduledoc). This is what lets two files
  # contributing outgoing edges for one merged entity (same qualified_name
  # across files of a source) each hold their own row instead of one
  # clobbering the other's contribution on delete+insert.
  defp upsert_edges(repo, staged_rows, chunk_ids_by_key, chunk_ids, entity_ids, def_entities, now) do
    aggregated =
      staged_rows
      |> Enum.reduce(%{}, fn row, acc ->
        case Map.get(chunk_ids_by_key, row.chunk_key) do
          nil ->
            # Same "shouldn't happen in practice" skip as mention_entries/3 —
            # every staged row in this job was just written, but a missing
            # chunk id must be skipped, not written as a bogus NULL-chunk_id
            # row (that column's NULL is reserved for pre-provenance legacy
            # rows, not new writes with an unresolved id).
            acc

          chunk_id ->
            row.graph
            |> Map.get(:references, [])
            |> Enum.reduce(acc, &accumulate_edge(&2, &1, entity_ids, chunk_id))
        end
      end)

    # Every reference's "from" name is (per accumulate_edge/4's contract) an
    # enclosing definition in this same file/batch, so this batch's
    # definition-entity ids are a superset of every id an edge could possibly
    # be sourced from — including definitions that used to have outgoing
    # edges but contributed nothing to `aggregated` this time (dropped all
    # their calls). Deleting only `aggregated`'s (possibly smaller) set of
    # source ids, as an earlier version did, left such a definition's stale
    # edges behind forever.
    def_entity_ids =
      def_entities
      |> Enum.map(&entity_ids[&1.qualified_name])
      |> Enum.reject(&is_nil/1)

    write_edges(repo, def_entity_ids, chunk_ids, aggregated, now)
  end

  # Only a reference with BOTH ends resolved (its enclosing definition AND
  # its target) becomes a candidate edge — an unresolved end means we never
  # saw a definition for one side, so there's no entity to point the edge at.
  defp accumulate_edge(acc, ref, entity_ids, chunk_id) do
    with from_name when not is_nil(from_name) <- Map.get(ref, :from),
         source_entity_id when not is_nil(source_entity_id) <- entity_ids[from_name],
         target_entity_id when not is_nil(target_entity_id) <- entity_ids[Map.fetch!(ref, :name)] do
      kind = edge_kind(Map.fetch!(ref, :kind))
      Map.update(acc, {source_entity_id, target_entity_id, kind, chunk_id}, 1, &(&1 + 1))
    else
      _ -> acc
    end
  end

  defp edge_kind(:call), do: :calls
  defp edge_kind(:import), do: :imports

  # Same rationale as ref_entity_kind/1's catch-all — fail clearly on an
  # extractor-seam value neither clause expects, instead of crashing with a
  # FunctionClauseError.
  defp edge_kind(other) do
    raise ArgumentError,
          "unknown edge kind #{inspect(other)} — expected :call or :import"
  end

  defp write_edges(repo, def_entity_ids, chunk_ids, aggregated, now) do
    # An entity's outgoing edges are re-derived per CHUNK, not per file: each
    # staged row's contribution is keyed by its own chunk_id (see
    # accumulate_edge/4), so this batch only needs to clear the rows THIS
    # batch's chunks are about to replace — `chunk_id in chunk_ids`. A merged
    # entity's edges contributed by a DIFFERENT file (different chunk ids)
    # are untouched, which is the fix: the old file-wide delete-then-rederive
    # let two files defining the same qualified_name clobber each other's
    # outgoing edges depending on ingest order.
    #
    # `is_nil(chunk_id) and source_entity_id in def_entity_ids` is
    # TRANSITIONAL: it reproduces the pre-provenance delete scope (every
    # definition entity resolved from this batch, so a definition that
    # dropped ALL its calls still sheds its stale edge even though
    # `aggregated` came back empty for it) for legacy rows that predate the
    # chunk_id column. It's scoped to this batch's own definition entities,
    # same known best-effort gap as before for those legacy rows: a
    # from-entity defined under the same qualified_name in two files can
    # still have its legacy (NULL chunk_id) edges clobbered by whichever
    # file is ingested last. This disjunct — and the gap — goes away once
    # every legacy row has been replaced by a chunk-scoped re-ingest.
    unless chunk_ids == [] and def_entity_ids == [] do
      repo.delete_all(
        from(e in EntityEdge,
          where:
            e.chunk_id in ^chunk_ids or
              (is_nil(e.chunk_id) and e.source_entity_id in ^def_entity_ids)
        )
      )
    end

    entries =
      aggregated
      # conflict key IS the map key here (source_entity_id, target_entity_id,
      # kind, chunk_id — matching EntityEdge's conflict_target below), so
      # sorting by key is sorting by conflict target directly — see
      # sort_by_conflict_key/2's comment.
      |> sort_by_conflict_key(fn {key, _weight} -> key end)
      |> Enum.map(fn {{source_entity_id, target_entity_id, kind, chunk_id}, weight} ->
        %{
          source_entity_id: source_entity_id,
          target_entity_id: target_entity_id,
          kind: kind,
          chunk_id: chunk_id,
          weight: weight,
          inserted_at: {:placeholder, :now},
          updated_at: {:placeholder, :now}
        }
      end)

    insert_all_batched(repo, EntityEdge, entries,
      placeholders: %{now: now},
      on_conflict: {:replace, [:weight, :updated_at]},
      conflict_target: [:source_entity_id, :target_entity_id, :kind, :chunk_id]
    )
  end

  # --- shared helpers ----------------------------------------------------

  # Sorts entries by their table's ON CONFLICT target tuple BEFORE they reach
  # insert_all_batched/4's Enum.chunk_every/2 — so the ordering holds across
  # batch boundaries too, not just within one batch. Two concurrent
  # SourceOwner processes (one per source with work) upserting overlapping
  # keys in different orders is the classic Postgres multi-row ON CONFLICT
  # deadlock:
  # if batch A locks {X, Y} in that order while batch B locks {Y, X}, each
  # acquires one row lock then blocks waiting on the other. Sorting every
  # batch by the same key makes lock acquisition order consistent across
  # transactions, so this can't happen.
  defp sort_by_conflict_key(entries, key_fun), do: Enum.sort_by(entries, key_fun)

  defp insert_all_batched(_repo, _schema, [], _opts), do: 0

  defp insert_all_batched(repo, schema, entries, opts) do
    entries
    |> Enum.chunk_every(insert_batch_size())
    |> Enum.reduce(0, fn batch, acc ->
      {_count, _} = repo.insert_all(schema, batch, opts)
      acc + length(batch)
    end)
  end

  defp insert_batch_size do
    size = Application.get_env(:retrieval_node, :graph_insert_batch_size, @insert_batch_size)
    validate_positive_batch_size!(size)
    size
  end

  # Strict allowlist against the schema's own enum, so an unknown atom from a
  # future extractor fails with a clear error instead of an Ecto dump error.
  defp entity_kind(kind) do
    if kind in Ecto.Enum.values(Entity, :kind) do
      kind
    else
      raise ArgumentError, "#{inspect(kind)} is not a valid Entity.kind"
    end
  end
end
