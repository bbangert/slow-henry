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

  The read side (`find_entities/2`, `related_entities/3`,
  `definition_snippets/2`) backs the `related_code` MCP tool. Every read here
  is bounded at a single choke point per dimension (result limit, hops,
  seed-id count, per-traversal fan-out, snippet size) so no caller can ask
  for an unbounded query.
  """

  import Ecto.Query

  require Logger

  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk

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

  Always scoped to ONE source, and must run inside that source's
  `Ingest.SourceOwner` (as `upsert_from_staged/3` does): the owner is the
  single writer of a source's graph rows, so no ingest pass can land a new
  mention on a candidate between this function's select and its delete. A
  caller outside the owner could race a pass and cascade away mentions it
  just committed, so there is deliberately no unscoped (all-sources) form;
  a corpus-wide sweep must go source by source through each owner.

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
  @spec gc_orphaned_entities(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def gc_orphaned_entities(source_id, opts \\ []) when is_binary(source_id) do
    batch_size = Keyword.get(opts, :batch_size, @gc_batch_size)
    validate_positive_batch_size!(batch_size)
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
    |> where([e], e.source_id == ^source_id)
  end

  # --- read-side queries ---------------------------------------------------

  @find_entities_default_limit 20
  @find_entities_max_limit 50
  @related_entities_relations [:callers, :callees, :imports, :importers]
  @related_entities_limit 50
  @definition_snippets_limit 50
  @snippet_max_lines 20
  @snippet_max_chars 1000

  # Symbols are capped at 256 bytes on write (@max_symbol_bytes), so a longer
  # lookup name can never match exactly and would only make the trigram tier
  # pay O(name x qualified_name) per candidate row.
  @max_name_bytes 256

  # Caps how many seed ids any traversal/snippet call accepts: an `IN` list
  # is a bind parameter per call, and every id fans out into its own edges.
  @max_seed_ids 100

  # Bounds a single edges_query/4 traversal — hot symbols (e.g. `init`,
  # `get`) can have six-figure in-degree in a many-repo corpus, and an
  # uncapped query would load every one of those edges into BEAM heap.
  @edge_fanout_limit 500

  # Caps how many hop-1 entity ids (by weight desc) are carried into the
  # hop-2 traversal — hop-2 fans out from EVERY id in the frontier, so an
  # uncapped frontier would multiply, not bound, the hop-1 fan-out risk.
  @hop2_frontier_limit 100

  @doc """
  Resolve `name` to matching entities, optionally scoped by `:repo`/`:lang`
  and capped at `:limit` (default #{@find_entities_default_limit}, max
  #{@find_entities_max_limit}). Three-tier resolution, each tier tried only
  if the previous found nothing:

    1. Exact `qualified_name` match.
    2. Suffix match (`qualified_name ILIKE "%.<name>"`) — so a bare name
       like `"process"` finds `"PaymentProcessor.process"`.
    3. Trigram best-effort (`qualified_name %> name`, ordered by
       `word_similarity(name, qualified_name)` desc) — for typos/near
       matches, served by the `entities_qualified_name_trgm_idx` GIN index.

  Exact and suffix results are ordered shortest-name-first, then by name and
  id, so a limit cut is deterministic.

  `entities` carries no `repo` column of its own — identity is scoped to
  `source_id`, not repo — so `:repo` filters via `EXISTS` against
  `entity_mentions` joined to `chunks` (does this entity have at least one
  mention on a chunk tagged with that repo?) rather than a direct column
  filter.

  Returns `[]` for a name or filter that can never match: not a valid
  string (non-UTF-8, contains NUL), blank, or over #{@max_name_bytes} bytes.
  """
  @spec find_entities(String.t(), keyword()) :: [Entity.t()]
  def find_entities(name, opts \\ []) do
    repo = Keyword.get(opts, :repo)
    lang = Keyword.get(opts, :lang)

    if valid_name?(name) and valid_filter?(repo) and valid_filter?(lang) do
      limit = opts |> Keyword.get(:limit, @find_entities_default_limit) |> clamp_find_limit()
      name = String.trim(name)

      base =
        from(e in Entity, as: :entity)
        |> filter_lang(lang)
        |> filter_repo(repo)

      with [] <- base |> exact_name_query(name) |> run_limited(limit),
           [] <- base |> suffix_name_query(name) |> run_limited(limit) do
        base |> trigram_name_query(name) |> run_limited(limit)
      else
        rows -> rows
      end
    else
      []
    end
  end

  defp valid_name?(name) when is_binary(name) do
    trimmed = String.trim(name)
    trimmed != "" and byte_size(trimmed) <= @max_name_bytes and storable_text?(trimmed)
  end

  defp valid_name?(_), do: false

  defp valid_filter?(nil), do: true
  defp valid_filter?(text) when is_binary(text), do: storable_text?(text)
  defp valid_filter?(_), do: false

  # Postgres text params reject invalid UTF-8 and NUL bytes (Postgrex raises).
  defp storable_text?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

  defp clamp_find_limit(n) when is_integer(n) and n > 0, do: min(n, @find_entities_max_limit)
  defp clamp_find_limit(_), do: @find_entities_default_limit

  defp filter_lang(query, nil), do: query
  defp filter_lang(query, lang), do: from(e in query, where: e.language == ^lang)

  defp filter_repo(query, nil), do: query

  defp filter_repo(query, repo) do
    from(e in query,
      where:
        exists(
          from(m in EntityMention,
            join: c in Chunk,
            on: c.id == m.chunk_id,
            where: m.entity_id == parent_as(:entity).id and c.repo == ^repo,
            select: 1
          )
        )
    )
  end

  defp exact_name_query(base, name) do
    from(e in base,
      where: e.qualified_name == ^name,
      order_by: [asc: e.qualified_name, asc: e.id]
    )
  end

  defp suffix_name_query(base, name) do
    # ilike/2 can't carry an ESCAPE clause, so the fragment form is required
    # to escape caller-supplied LIKE metacharacters — otherwise e.g.
    # `name: "%"` would ILIKE-match every dotted qualified_name corpus-wide.
    pattern = "%." <> escape_like(name)

    from(e in base,
      where: fragment("? ILIKE ? ESCAPE '\\'", e.qualified_name, ^pattern),
      order_by: [asc: fragment("length(?)", e.qualified_name), asc: e.qualified_name, asc: e.id]
    )
  end

  defp escape_like(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")

  defp trigram_name_query(base, name) do
    from(e in base,
      where: fragment("? %> ?", e.qualified_name, ^name),
      order_by: [
        desc: fragment("word_similarity(?, ?)", ^name, e.qualified_name),
        asc: e.qualified_name,
        asc: e.id
      ]
    )
  end

  defp run_limited(query, limit), do: query |> limit(^limit) |> Repo.all()

  @doc """
  Traverse from `entity_ids` along `relation`, 1 or 2 hops:

    * `:callers`   — edges kind `:calls`, `target_entity_id` in the set;
      returns the calling (source) entities.
    * `:callees`   — edges kind `:calls`, `source_entity_id` in the set;
      returns the called (target) entities.
    * `:importers` — entities that import the matched entities.
    * `:imports`   — entities the matched entities import.

  `:callers`/`:callees` traverse `entity_edges` only. `:importers`/`:imports`
  UNION two resolution legs, deduped by entity id (ties keep the larger
  weight):

    1. `entity_edges` kind `:imports` (same shape as callers/callees) — fires
       when a reference happened to resolve a `from` (an import inside a
       function/method scope, say).
    2. Mention-based: a **file-level** import — the common case — carries
       `from: nil` (no enclosing definition to source an edge from), so it
       never produces an `entity_edges` row at all. Its only record is two
       `entity_mentions` sharing one `chunk_id`: an `:import` mention of the
       imported entity and a `:definition` mention of the importing file's
       definition entity on that same chunk. `:importers` of X resolves this
       by finding chunks with an `:import` mention of X, then those chunks'
       `:definition` mentions; `:imports` of X resolves the opposite
       direction (chunks with a `:definition` mention of X, then those
       chunks' `:import` mentions). Weight is the count of qualifying import
       mentions.

  The mention leg counts only import mentions that no `:imports` edge on the
  same chunk explains (a scoped import writes both an edge and a mention; the
  edge leg already attributes it). Mentions are unique per (entity, chunk,
  kind), so a chunk holding both a file-level and a scoped import of the same
  entity cannot be told apart: that mention is treated as explained, and only
  the scoped importer is reported. Mention-leg weight is per (seed, result)
  pair; pairs combine across seeds by max, not sum.

  `hops: 2` repeats the same resolution (both legs, for imports/importers)
  starting from the first hop's entities, unions the two hops, and dedups by
  entity — an entity reached at hop 1 is excluded from the hop-2 set (so it
  keeps its hop-1 weight/tag), and the original seed ids are excluded from
  both hops (guards against a traversal cycling back to a seed). Ties within
  a hop (the same entity reachable more than once) keep the larger weight.
  Final results are ordered by weight desc (entity id breaks ties) and capped
  at #{@related_entities_limit}.

  Bounds: at most #{@max_seed_ids} distinct seed ids are used; each
  underlying query (edge or mention leg) is itself capped at
  #{@edge_fanout_limit} rows (ordered by weight/count desc — see
  `edges_query/4` and the mention-leg query functions), and the hop-1 ->
  hop-2 frontier is capped at #{@hop2_frontier_limit} entity ids (also by
  weight desc) so a hot symbol's fan-out can't compound across two hops into
  an unbounded traversal. Raises `ArgumentError` for an unknown `relation`
  or `hops` outside 1..2.

  Traversal never crosses sources: edges are written between entities of one
  source, and the mention legs join on a shared chunk.
  """
  @spec related_entities([Ecto.UUID.t()], :callers | :callees | :imports | :importers, 1 | 2) ::
          [%{entity: Entity.t(), weight: integer(), hop: 1 | 2}]
  def related_entities(entity_ids, relation, hops \\ 1)

  def related_entities(entity_ids, relation, hops)
      when is_list(entity_ids) and relation in @related_entities_relations and hops in [1, 2] do
    case clamp_seed_ids(entity_ids) do
      [] -> []
      seed_list -> traverse(seed_list, relation, hops)
    end
  end

  def related_entities(_entity_ids, relation, hops) do
    raise ArgumentError,
          "related_entities/3 expects a list of ids, relation in " <>
            "#{inspect(@related_entities_relations)} and hops 1 or 2, " <>
            "got relation=#{inspect(relation)} hops=#{inspect(hops)}"
  end

  defp clamp_seed_ids(ids), do: ids |> Enum.uniq() |> Enum.take(@max_seed_ids)

  defp traverse(seed_list, relation, hops) do
    seed_ids = MapSet.new(seed_list)

    hop1 =
      seed_list
      |> traverse_edges(relation)
      |> reject_seen(seed_ids)
      |> dedup_max_weight()

    tagged_hop1 = Enum.map(hop1, &Map.put(&1, :hop, 1))

    tagged =
      if hops == 1 do
        tagged_hop1
      else
        excluded = MapSet.union(seed_ids, MapSet.new(hop1, & &1.entity_id))

        # hop-1 is already bounded by @edge_fanout_limit per query, but
        # feeding all of it into a second traversal would multiply that
        # fan-out instead of bounding it.
        hop2_frontier =
          hop1
          |> rank()
          |> Enum.take(@hop2_frontier_limit)
          |> Enum.map(& &1.entity_id)

        hop2 =
          hop2_frontier
          |> traverse_edges(relation)
          |> reject_seen(excluded)
          |> dedup_max_weight()
          |> Enum.map(&Map.put(&1, :hop, 2))

        tagged_hop1 ++ hop2
      end

    # Rank and cut BEFORE loading entity rows so at most
    # @related_entities_limit rows are ever fetched.
    top = tagged |> rank() |> Enum.take(@related_entities_limit)
    entities_by_id = load_entities(Enum.map(top, & &1.entity_id))

    Enum.flat_map(top, fn %{entity_id: id, weight: weight, hop: hop} ->
      case Map.fetch(entities_by_id, id) do
        {:ok, entity} -> [%{entity: entity, weight: weight, hop: hop}]
        :error -> []
      end
    end)
  end

  defp rank(rows), do: Enum.sort_by(rows, &{-&1.weight, &1.entity_id})

  defp reject_seen(rows, ids), do: Enum.reject(rows, &MapSet.member?(ids, &1.entity_id))

  defp dedup_max_weight(rows) do
    rows
    |> Enum.reduce(%{}, fn %{entity_id: id, weight: w}, acc ->
      Map.update(acc, id, w, &max(&1, w))
    end)
    |> Enum.map(fn {id, w} -> %{entity_id: id, weight: w} end)
  end

  defp traverse_edges(ids, :callers),
    do: edges_query(ids, :calls, :target_entity_id, :source_entity_id)

  defp traverse_edges(ids, :callees),
    do: edges_query(ids, :calls, :source_entity_id, :target_entity_id)

  defp traverse_edges(ids, :importers),
    do:
      edges_query(ids, :imports, :target_entity_id, :source_entity_id) ++
        importers_by_mention(ids)

  defp traverse_edges(ids, :imports),
    do:
      edges_query(ids, :imports, :source_entity_id, :target_entity_id) ++ imports_by_mention(ids)

  # A logical (source, target, kind) edge can back onto MULTIPLE entity_edges
  # rows — one per contributing chunk (see EntityEdge's moduledoc) — so this
  # groups by the entity pair before a consumer ever sees a row, summing each
  # pair's chunk-level weights into one logical weight.
  defp edges_query(ids, kind, filter_field, select_field) do
    from(e in EntityEdge,
      where: e.kind == ^kind and field(e, ^filter_field) in ^ids,
      group_by: [e.source_entity_id, e.target_entity_id],
      select: %{entity_id: field(e, ^select_field), weight: type(sum(e.weight), :integer)},
      order_by: [desc: sum(e.weight), asc: field(e, ^select_field)],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
  end

  # Mention-based leg of :importers (see related_entities/3): the :definition
  # mentions on chunks carrying an :import mention of one of `ids`. Weight is
  # per (seed, importer) pair — the count of qualifying import mentions — and
  # pairs are combined across seeds by dedup_max_weight/1, never summed.
  # Bounded like edges_query/4.
  defp importers_by_mention(ids) do
    from(m in EntityMention,
      as: :imp,
      join: d in EntityMention,
      on: d.chunk_id == m.chunk_id and d.kind == :definition,
      where: m.kind == :import and m.entity_id in ^ids and d.entity_id not in ^ids,
      where: not exists(import_edge_on_chunk(:imp)),
      group_by: [m.entity_id, d.entity_id],
      select: %{entity_id: d.entity_id, weight: count(m.id)},
      order_by: [desc: count(m.id), asc: d.entity_id, asc: m.entity_id],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
  end

  # Mirror image of importers_by_mention/1.
  defp imports_by_mention(ids) do
    from(m in EntityMention,
      join: i in EntityMention,
      as: :imp,
      on: i.chunk_id == m.chunk_id and i.kind == :import,
      where: m.kind == :definition and m.entity_id in ^ids and i.entity_id not in ^ids,
      where: not exists(import_edge_on_chunk(:imp)),
      group_by: [m.entity_id, i.entity_id],
      select: %{entity_id: i.entity_id, weight: count(i.id)},
      order_by: [desc: count(i.id), asc: i.entity_id, asc: m.entity_id],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
  end

  # An :import mention that an :imports edge on the same chunk explains: a
  # scoped import (reference with a `from`) writes both, and the edge leg
  # already attributes it to the right definition. The mention leg must only
  # count what no edge explains (file-level imports), or every other
  # definition sharing the chunk would be misreported.
  defp import_edge_on_chunk(binding) do
    from(e in EntityEdge,
      where:
        e.kind == :imports and e.target_entity_id == parent_as(^binding).entity_id and
          e.chunk_id == parent_as(^binding).chunk_id,
      select: 1
    )
  end

  defp load_entities([]), do: %{}

  defp load_entities(ids) do
    Entity
    |> where([e], e.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Definition-site snippets for `entity_ids` — the chunk(s) where each entity
  has a `:definition` mention (at most #{@max_seed_ids} distinct ids are
  used). One query, shaped in memory; capped at `:limit` rows total (default
  and max #{@definition_snippets_limit}), ordered by entity id then chunk id
  so the cut is deterministic.

  Each snippet is the defining chunk's `content` truncated to whichever of
  #{@snippet_max_lines} lines or #{@snippet_max_chars} code points cuts
  first, with a trailing "…" marker exactly when the snippet differs from the
  stored content. The code-point cut happens in SQL so a large chunk's full
  content never reaches the BEAM; the line cut is applied to that prefix.
  """
  @spec definition_snippets([Ecto.UUID.t()], keyword()) :: [map()]
  def definition_snippets(entity_ids, opts \\ [])

  def definition_snippets([], _opts), do: []

  def definition_snippets(entity_ids, opts) when is_list(entity_ids) do
    limit = opts |> Keyword.get(:limit, @definition_snippets_limit) |> clamp_snippet_limit()
    max_chars = @snippet_max_chars

    from(m in EntityMention,
      join: c in Chunk,
      on: c.id == m.chunk_id,
      where: m.kind == :definition and m.entity_id in ^clamp_seed_ids(entity_ids),
      order_by: [asc: m.entity_id, asc: c.id],
      select: %{
        entity_id: m.entity_id,
        repo: c.repo,
        lang: c.lang,
        path: fragment("?->>'path'", c.metadata),
        breadcrumb: c.context_breadcrumb,
        content: fragment("left(?, ?)", c.content, ^max_chars),
        char_truncated?: fragment("char_length(?) > ?", c.content, ^max_chars)
      },
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&shape_snippet/1)
  end

  defp clamp_snippet_limit(n) when is_integer(n) and n > 0, do: min(n, @definition_snippets_limit)
  defp clamp_snippet_limit(_), do: @definition_snippets_limit

  defp shape_snippet(row) do
    %{
      entity_id: row.entity_id,
      repo: row.repo,
      lang: row.lang,
      path: row.path,
      breadcrumb: row.breadcrumb,
      snippet: truncate_snippet(row.content || "", row.char_truncated?)
    }
  end

  defp truncate_snippet(prefix, char_truncated?) do
    lines = String.split(prefix, "\n")
    line_capped? = length(lines) > @snippet_max_lines
    by_lines = lines |> Enum.take(@snippet_max_lines) |> Enum.join("\n")

    if char_truncated? or line_capped?, do: by_lines <> "…", else: by_lines
  end

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
