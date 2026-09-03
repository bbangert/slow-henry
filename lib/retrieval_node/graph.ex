defmodule RetrievalNode.Graph do
  @moduledoc """
  Owns the write path for the code-knowledge-graph tables (`entities`,
  `entity_mentions`, `entity_edges`). Touches `Repo` directly — like `Bench`
  and the `Ingest` context modules, a deliberate exception to the
  one-context-per-table boundary: this module IS the context responsible for
  those three tables, not a call-site reaching around one.

  Called from inside `Ingest.Workers.UpsertChunks`' transaction — every
  `insert_all`/`delete_all` here runs against the same `repo` (the sandboxed
  connection for that transaction), and `chunk_ids_by_key` is the id map
  UpsertChunks just produced from its own (possibly ON CONFLICT-preserved)
  chunk insert.

  `upsert_from_staged/3` assumes all `staged_rows` come from one
  `ChunkFiles` job's worth of chunks (one source file, hence one
  `source_id`) — the same assumption `UpsertChunks` already relies on
  implicitly for its own chunk upsert.

  Also owns the read side of the same three tables — `find_entities/2`,
  `related_entities/3`, `definition_snippets/2` — used by the `related_code`
  MCP tool to answer "who calls X" / "what does X call" / "where is X
  defined" / "who imports X".
  """

  import Ecto.Query

  require Logger

  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk

  # Same 65,535-bind-parameter ceiling as PendingChunks/UpsertChunks (see
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
  Upsert entities/mentions/edges derived from `staged_rows`' `graph` jsonb
  column into the permanent graph tables. Returns counts for logging (the
  caller doesn't log them itself — the Multi result just carries them).
  """
  @spec upsert_from_staged(Ecto.Repo.t(), [struct()], %{String.t() => Ecto.UUID.t()}) ::
          {:ok, counts}
  def upsert_from_staged(_repo, [], _chunk_ids_by_key),
    do: {:ok, %{entities: 0, mentions: 0, edges: 0}}

  def upsert_from_staged(repo, staged_rows, chunk_ids_by_key) do
    now = DateTime.utc_now()
    staged_rows = Enum.map(staged_rows, &sanitize_graph/1)
    source_id = staged_rows |> hd() |> Map.fetch!(:source_id)

    # write_edges/2's per-from-entity delete-then-rederive safety argument
    # assumes every row in this batch belongs to one source (one file) —
    # UpsertChunks batches are per-file today; this pins that assumption so a
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
  Deletes entities with zero remaining `entity_mentions` — the ingest
  pipeline's file-deletion path (`Repo.delete_all` on `chunks` by
  `source_id`/path) cascades away the mentions on those chunks but has no
  reason to know about the entities they used to point at, so a
  zero-mention entity is a durable orphan until something reaps it. Its
  `entity_edges` rows die for free via their own `entities` FK cascade —
  no separate edge cleanup needed here. Chunk-provenance edge rows (those
  carrying a non-NULL `chunk_id`) additionally cascade the moment their
  owning chunk is deleted, via `entity_edges.chunk_id`'s own FK — same
  lifecycle as `entity_mentions` — so this GC's job for those rows is
  already partly done by the time an entity goes zero-mention; the
  `entities` FK cascade above remains the catch-all for whatever a chunk
  deletion didn't reach (e.g. legacy NULL-`chunk_id` edge rows).

  Deletes in batches of `:batch_size` (default 10,000) rather than one
  statement: `entities` is sized for a many-repo corpus (can reach into the
  millions of rows), and one unbounded `DELETE` would hold its row locks
  and accumulate undo/WAL for the entire scan instead of releasing them
  between batches. Loops until a round's candidate select comes back
  shorter than a full batch (see `delete_orphaned_batch/1` for why this is
  no longer "deletes fewer than a batch" — the recheck it does can now
  legitimately delete less than it selected). Returns the total number of
  entities deleted. Raises `ArgumentError` if `:batch_size` is not a positive
  integer — a non-positive batch never returns fewer candidates than itself,
  which would otherwise recurse forever on an empty batch.

  Each batch selects and deletes inside one transaction, locking candidates
  against a concurrent `UpsertChunks` upsert (queue concurrency 5) landing a
  new mention in the gap between classification and delete — see
  `delete_orphaned_batch/1`.
  """
  @spec gc_orphaned_entities(keyword()) :: non_neg_integer()
  def gc_orphaned_entities(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @gc_batch_size)
    validate_positive_batch_size!(batch_size)
    gc_batches(batch_size, 0)
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

  defp gc_batches(batch_size, total) do
    {candidate_count, deleted} = delete_orphaned_batch(batch_size)
    total = total + deleted

    if candidate_count < batch_size do
      total
    else
      gc_batches(batch_size, total)
    end
  end

  # A plain "SELECT zero-mention ids, then DELETE those ids" (the previous
  # shape) is a snapshot race: a mention committed by a concurrent
  # UpsertChunks between the SELECT and the DELETE is invisible to the
  # SELECT's NOT EXISTS, so its entity looks orphaned and gets deleted
  # anyway — cascading away the just-inserted mention along with it.
  #
  # Fixed with lock-then-recheck, both inside one transaction:
  #
  #   1. SELECT candidate ids `FOR UPDATE SKIP LOCKED`. This takes a row lock
  #      on each candidate entity. SKIP LOCKED means GC never blocks behind
  #      an in-flight UpsertChunks transaction that's already touching one of
  #      these rows (e.g. via its own FK-driven lock) — it just moves on to
  #      the next candidate and picks this one up on a later run instead.
  #   2. DELETE those ids with the SAME zero-mention condition rechecked in
  #      the DELETE's own WHERE. A concurrent mention INSERT must acquire a
  #      FOR KEY SHARE lock on its parent entity row (Postgres does this
  #      automatically for the FK reference) — which now blocks on our FOR
  #      UPDATE until this transaction commits or rolls back. So by the time
  #      the DELETE runs, any mention that could still land on a candidate
  #      has either already committed (making the recheck's NOT EXISTS catch
  #      it and spare the row) or is blocked until we're done (and lands
  #      after, on a surviving row, since we only deleted what still had zero
  #      mentions at DELETE time).
  #
  # Consequence: a round can now delete FEWER rows than it selected as
  # candidates (some got spared by the recheck) — the candidate count, not
  # the delete count, is what gc_batches/2 uses to decide whether to loop
  # again.
  defp delete_orphaned_batch(batch_size) do
    {:ok, {candidate_count, deleted}} =
      Repo.transaction(fn ->
        orphan_ids =
          from(e in Entity,
            as: :entity,
            where:
              not exists(
                from(m in EntityMention, where: m.entity_id == parent_as(:entity).id, select: 1)
              ),
            select: e.id,
            limit: ^batch_size,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> Repo.all()

        deleted = delete_still_orphaned(orphan_ids)

        {length(orphan_ids), deleted}
      end)

    {candidate_count, deleted}
  end

  defp delete_still_orphaned([]), do: 0

  defp delete_still_orphaned(ids) do
    {count, _} =
      Repo.delete_all(
        from(e in Entity,
          as: :entity,
          where: e.id in ^ids,
          where:
            not exists(
              from(m in EntityMention, where: m.entity_id == parent_as(:entity).id, select: 1)
            )
        )
      )

    count
  end

  # --- read-side queries ---------------------------------------------------

  @find_entities_default_limit 20
  @find_entities_max_limit 50
  @related_entities_relations [:callers, :callees, :imports, :importers]
  @related_entities_limit 50
  @definition_snippets_limit 50
  @snippet_max_lines 20
  @snippet_max_chars 1000

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
       matches, same pg_trgm index `HybridQuery`'s entity leg uses.

  `entities` carries no `repo` column of its own — identity is scoped to
  `source_id`, not repo — so `:repo` filters via `EXISTS` against
  `entity_mentions` joined to `chunks` (does this entity have at least one
  mention on a chunk tagged with that repo?) rather than a direct column
  filter.
  """
  @spec find_entities(String.t(), keyword()) :: [Entity.t()]
  def find_entities(name, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @find_entities_default_limit) |> clamp_find_limit()

    base =
      from(e in Entity, as: :entity)
      |> filter_lang(Keyword.get(opts, :lang))
      |> filter_repo(Keyword.get(opts, :repo))

    with [] <- base |> exact_name_query(name) |> run_limited(limit),
         [] <- base |> suffix_name_query(name) |> run_limited(limit) do
      base |> trigram_name_query(name) |> run_limited(limit)
    else
      rows -> rows
    end
  end

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

  defp exact_name_query(base, name), do: from(e in base, where: e.qualified_name == ^name)

  defp suffix_name_query(base, name) do
    # ilike/2 can't carry an ESCAPE clause, so the fragment form is required
    # to escape caller-supplied LIKE metacharacters — otherwise e.g.
    # `name: "%"` would ILIKE-match every dotted qualified_name corpus-wide.
    pattern = "%." <> escape_like(name)
    from(e in base, where: fragment("? ILIKE ? ESCAPE '\\'", e.qualified_name, ^pattern))
  end

  # Same escaping as Bench.Runner.like_pattern/1.
  defp escape_like(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")

  defp trigram_name_query(base, name) do
    from(e in base,
      where: fragment("? %> ?", e.qualified_name, ^name),
      order_by: [desc: fragment("word_similarity(?, ?)", ^name, e.qualified_name)]
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

  `hops: 2` repeats the same resolution (both legs, for imports/importers)
  starting from the first hop's entities, unions the two hops, and dedups by
  entity — an entity reached at hop 1 is excluded from the hop-2 set (so it
  keeps its hop-1 weight/tag), and the original seed ids are excluded from
  both hops (guards against a traversal cycling back to a seed). Ties within
  a hop (the same entity reachable more than once) keep the larger weight.
  Final results are ordered by weight desc and capped at
  #{@related_entities_limit}.

  Each underlying query (edge or mention leg) is itself capped at
  #{@edge_fanout_limit} rows (ordered by weight/count desc — see
  `edges_query/4` and the mention-leg query functions), and the hop-1 ->
  hop-2 frontier is capped at #{@hop2_frontier_limit} entity ids (also by
  weight desc) so a hot symbol's fan-out can't compound across two hops into
  an unbounded traversal.
  """
  @spec related_entities([Ecto.UUID.t()], :callers | :callees | :imports | :importers, 1 | 2) ::
          [%{entity: Entity.t(), weight: integer(), hop: 1 | 2}]
  def related_entities(entity_ids, relation, hops \\ 1)

  def related_entities(entity_ids, relation, hops)
      when relation in @related_entities_relations and hops in [1, 2] do
    seed_ids = MapSet.new(entity_ids)

    hop1 =
      entity_ids
      |> traverse_edges(relation)
      |> reject_seen(seed_ids)
      |> dedup_max_weight()

    tagged_hop1 = Enum.map(hop1, &Map.put(&1, :hop, 1))

    tagged =
      if hops == 1 do
        tagged_hop1
      else
        excluded = MapSet.union(seed_ids, MapSet.new(hop1, & &1.entity_id))

        # Cap the hop-2 frontier to the top @hop2_frontier_limit hop-1 ids by
        # weight — hop-1 itself is uncapped in-memory (it's already bounded
        # by @edge_fanout_limit at the query level), but feeding all of it
        # into a second traversal would multiply that fan-out instead of
        # bounding it.
        hop2_frontier =
          hop1
          |> Enum.sort_by(&(-&1.weight))
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

    entities_by_id = load_entities(Enum.map(tagged, & &1.entity_id))

    tagged
    |> Enum.sort_by(&(-&1.weight))
    |> Enum.take(@related_entities_limit)
    |> Enum.flat_map(fn %{entity_id: id, weight: weight, hop: hop} ->
      case Map.fetch(entities_by_id, id) do
        {:ok, entity} -> [%{entity: entity, weight: weight, hop: hop}]
        :error -> []
      end
    end)
  end

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

  # A logical (source, target, kind) edge can now back onto MULTIPLE
  # entity_edges rows — one per contributing chunk (see EntityEdge's
  # moduledoc) — so this groups by the entity pair before a consumer ever
  # sees a row, summing each pair's chunk-level weights into one logical
  # weight. Without this, a merged entity's edge contributed by two files
  # would surface as two separate (lower-weight) rows instead of one.
  defp edges_query(ids, kind, filter_field, select_field) do
    from(e in EntityEdge,
      where: e.kind == ^kind and field(e, ^filter_field) in ^ids,
      group_by: [e.source_entity_id, e.target_entity_id],
      select: %{entity_id: field(e, ^select_field), weight: sum(e.weight)},
      # Bounds one traversal query — hot symbols like `init` can have
      # six-figure in-degree in a many-repo corpus.
      order_by: [desc: sum(e.weight)],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
  end

  # Mention-based leg of :importers — see related_entities/3's doc for why
  # this exists (file-level imports have `from: nil` and so never produce an
  # entity_edges row). Finds chunks carrying an :import mention of one of
  # `ids`, then those chunks' :definition mentions — the defining entity of
  # each such chunk is "an importer of X". Weight is the count of qualifying
  # import mentions per resulting entity. Bounded at @edge_fanout_limit rows,
  # same rationale as edges_query/4 — a widely-imported module could
  # otherwise pull an unbounded number of importing chunks into memory.
  defp importers_by_mention(ids) do
    from(m in EntityMention,
      join: d in EntityMention,
      on: d.chunk_id == m.chunk_id and d.kind == :definition,
      where: m.kind == :import and m.entity_id in ^ids and d.entity_id not in ^ids,
      group_by: d.entity_id,
      select: %{entity_id: d.entity_id, weight: count(m.id)},
      order_by: [desc: count(m.id)],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
  end

  # Mention-based leg of :imports — the mirror image of importers_by_mention/1:
  # chunks carrying a :definition mention of one of `ids`, then those chunks'
  # :import mentions — each imported entity is "imported by X". Same bound
  # and weight rationale as importers_by_mention/1.
  defp imports_by_mention(ids) do
    from(m in EntityMention,
      join: i in EntityMention,
      on: i.chunk_id == m.chunk_id and i.kind == :import,
      where: m.kind == :definition and m.entity_id in ^ids and i.entity_id not in ^ids,
      group_by: i.entity_id,
      select: %{entity_id: i.entity_id, weight: count(i.id)},
      order_by: [desc: count(i.id)],
      limit: @edge_fanout_limit
    )
    |> Repo.all()
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
  has a `:definition` mention. One query, shaped in memory; capped at
  `:limit` rows total (default and max #{@definition_snippets_limit}).

  Each snippet is the defining chunk's `content` truncated to whichever of
  #{@snippet_max_lines} lines or #{@snippet_max_chars} chars cuts first
  (line cut applied before the char cut), with a trailing "…" marker when
  either cut actually truncated the content.
  """
  @spec definition_snippets([Ecto.UUID.t()], keyword()) :: [map()]
  def definition_snippets(entity_ids, opts \\ [])

  def definition_snippets([], _opts), do: []

  def definition_snippets(entity_ids, opts) do
    limit = opts |> Keyword.get(:limit, @definition_snippets_limit) |> clamp_snippet_limit()

    from(m in EntityMention,
      join: c in Chunk,
      on: c.id == m.chunk_id,
      where: m.kind == :definition and m.entity_id in ^entity_ids,
      select: %{
        entity_id: m.entity_id,
        repo: c.repo,
        lang: c.lang,
        path: fragment("?->>'path'", c.metadata),
        breadcrumb: c.context_breadcrumb,
        content: c.content
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
      snippet: truncate_snippet(row.content)
    }
  end

  defp truncate_snippet(content) do
    lines = String.split(content, "\n")
    line_capped? = length(lines) > @snippet_max_lines
    by_lines = lines |> Enum.take(@snippet_max_lines) |> Enum.join("\n")

    cond do
      String.length(by_lines) > @snippet_max_chars ->
        String.slice(by_lines, 0, @snippet_max_chars) <> "…"

      line_capped? ->
        by_lines <> "…"

      true ->
        by_lines
    end
  end

  # --- staged-graph sanitation --------------------------------------------

  # Mirrors Extractor.TreeSitter's @max_symbol_bytes emission cap. This is
  # defense-in-depth at the consumer: rows staged by an older/other producer
  # (or already sitting in pending_chunks when a cap ships) can still carry
  # oversized names, and one such row past the entities unique btree index's
  # ~2,700-byte row limit fails the INSERT and — after max_attempts — discards
  # the whole UpsertChunks job, losing every chunk in the file. Dropped with a
  # warning rather than raised: junk symbols must never take real chunks down.
  #
  # Shape, not just size, is validated here — at two levels:
  #
  #   1. Container: `"entities"`/`"references"` themselves must be lists.
  #      `graph` is jsonb, so nothing upstream of this function guarantees
  #      that — a present-but-non-list value (`null`, a string, an object)
  #      would otherwise reach `Enum.filter/2`/`length/1` below and raise.
  #   2. Element: a non-map element, or a missing/non-binary name or kind,
  #      would otherwise reach collect_definitions'/collect_reference_entities'
  #      `Map.fetch!("qualified_name"/"name"/"kind")` calls and raise there
  #      instead — rolling back the same Multi this sanitizer exists to
  #      protect.
  #
  # Both raise inside the same Multi transaction, so both are dropped with a
  # warning instead: junk symbols (or a malformed container) must never take
  # real chunks down. A non-list container's contents can't be individually
  # counted (there's nothing to iterate), so it's counted as a single dropped
  # container in the warning below. Every element surviving sanitize_graph/1
  # is guaranteed to be a map with a binary name field (under `key`) AND a
  # binary "kind" field, both within/subject to @max_symbol_bytes for the
  # name — which is what makes those later Map.fetch! calls safe by
  # construction (an unknown-but-binary kind still raises downstream in
  # kind_atom/3 / ref_entity_kind/1 / etc. — deliberately, per r2).
  @max_symbol_bytes 256

  defp sanitize_graph(%{graph: graph} = row) when graph == %{} or is_nil(graph), do: row

  defp sanitize_graph(row) do
    {kept_entities, entities_dropped} =
      row.graph |> Map.get("entities", []) |> filter_symbols("qualified_name")

    {kept_references, references_dropped} =
      row.graph |> Map.get("references", []) |> filter_symbols("name")

    dropped = entities_dropped + references_dropped

    if dropped > 0 do
      Logger.warning(
        "dropping #{dropped} invalid or oversized graph symbol(s) " <>
          "(non-list container, malformed shape, or > #{@max_symbol_bytes} bytes) " <>
          "from natural_key=#{inspect(row.natural_key)}"
      )
    end

    # Map.put (not map-update syntax): a staged graph may legitimately carry
    # only one of the two keys, and %{map | ...} raises on an absent key.
    sanitized =
      row.graph
      |> Map.put("entities", kept_entities)
      |> Map.put("references", kept_references)

    %{row | graph: sanitized}
  end

  # Normalizes a raw "entities"/"references" value before filtering: a
  # non-list value (nil, a string, a map — anything a jsonb column doesn't
  # constrain out) is treated as empty and its (uncountable) contents counted
  # as exactly one dropped container, rather than reaching `Enum.filter/2` or
  # `length/1` on a non-list and raising.
  defp filter_symbols(value, key) do
    case as_list(value) do
      :invalid ->
        {[], 1}

      list ->
        kept = Enum.filter(list, &valid_symbol?(&1, key))
        {kept, length(list) - length(kept)}
    end
  end

  defp as_list(list) when is_list(list), do: list
  defp as_list(_), do: :invalid

  # An element survives only if it's a map carrying a binary name (under
  # `key`) no longer than @max_symbol_bytes AND a binary "kind" — a non-map
  # element, a missing key, or a non-binary value (e.g. a `nil`
  # qualified_name, or a `kind` that isn't a string) is dropped as malformed
  # here instead of raising on `byte_size/1` or a downstream `Map.fetch!`/
  # `kind_atom/3` FunctionClauseError. An unknown-but-binary kind still
  # raises downstream, deliberately (per r2) — this gate only enforces shape.
  defp valid_symbol?(el, key) when is_map(el) do
    with name when is_binary(name) <- Map.get(el, key),
         true <- byte_size(name) <= @max_symbol_bytes,
         kind when is_binary(kind) <- Map.get(el, "kind") do
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
      |> Map.get("entities", [])
      |> Enum.map(&definition_attrs(row, &1))
    end)
    # Last write wins for an (unexpected) duplicate key within this batch —
    # the on_conflict replace below makes the DB state converge either way.
    |> Enum.reduce(%{}, fn attrs, acc ->
      Map.put(acc, {attrs.source_id, attrs.language, attrs.qualified_name}, attrs)
    end)
    |> Map.values()
  end

  defp definition_attrs(row, entity) do
    %{
      source_id: row.source_id,
      language: row.lang,
      qualified_name: Map.fetch!(entity, "qualified_name"),
      kind: kind_atom(Entity, :kind, Map.fetch!(entity, "kind")),
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
      |> Map.get("references", [])
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
      qualified_name: Map.fetch!(ref, "name"),
      kind: ref_entity_kind(Map.fetch!(ref, "kind")),
      path: nil
    }
  end

  defp ref_entity_kind("call"), do: :function
  defp ref_entity_kind("import"), do: :module

  # Staged graph jsonb is extractor-produced; the LLM-extractor seam means a
  # future producer could emit a ref kind neither TreeSitter clause expects.
  # Fail with a clear ArgumentError here rather than a FunctionClauseError
  # deep inside UpsertChunks' transaction.
  defp ref_entity_kind(other) do
    raise ArgumentError,
          "unknown reference kind #{inspect(other)} — expected \"call\" or \"import\""
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
    Map.get(graph, "entities", []) != [] or Map.get(graph, "references", []) != []
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
  # UpsertChunks' own insert (shouldn't happen in practice — every staged row
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
    |> Map.get("entities", [])
    |> Enum.map(&entity_ids[Map.fetch!(&1, "qualified_name")])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&mention_entry(&1, chunk_id, :definition))
  end

  defp reference_mentions(row, chunk_id, entity_ids) do
    row.graph
    |> Map.get("references", [])
    |> Enum.map(fn ref ->
      {entity_ids[Map.fetch!(ref, "name")], mention_kind(Map.fetch!(ref, "kind"))}
    end)
    |> Enum.reject(fn {entity_id, _kind} -> is_nil(entity_id) end)
    |> Enum.map(fn {entity_id, kind} -> mention_entry(entity_id, chunk_id, kind) end)
  end

  defp mention_kind("call"), do: :call
  defp mention_kind("import"), do: :import

  # Same rationale as ref_entity_kind/1's catch-all — fail clearly on an
  # extractor-seam value neither clause expects, instead of crashing with a
  # FunctionClauseError.
  defp mention_kind(other) do
    raise ArgumentError,
          "unknown mention kind #{inspect(other)} — expected \"call\" or \"import\""
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
            |> Map.get("references", [])
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
    with from_name when not is_nil(from_name) <- Map.get(ref, "from"),
         source_entity_id when not is_nil(source_entity_id) <- entity_ids[from_name],
         target_entity_id when not is_nil(target_entity_id) <- entity_ids[Map.fetch!(ref, "name")] do
      kind = edge_kind(Map.fetch!(ref, "kind"))
      Map.update(acc, {source_entity_id, target_entity_id, kind, chunk_id}, 1, &(&1 + 1))
    else
      _ -> acc
    end
  end

  defp edge_kind("call"), do: :calls
  defp edge_kind("import"), do: :imports

  # Same rationale as ref_entity_kind/1's catch-all — fail clearly on an
  # extractor-seam value neither clause expects, instead of crashing with a
  # FunctionClauseError.
  defp edge_kind(other) do
    raise ArgumentError,
          "unknown edge kind #{inspect(other)} — expected \"call\" or \"import\""
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
  # UpsertChunks jobs (queue concurrency 5) upserting overlapping keys in
  # different orders is the classic Postgres multi-row ON CONFLICT deadlock:
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

  # Ecto.Enum's dump values are looked up rather than String.to_existing_atom/1
  # (same reasoning as UpsertChunks.to_enum/2): atom interning is load-order
  # dependent, and this stays a strict allowlist against the schema's own enum.
  defp kind_atom(schema, field, value) when is_binary(value) do
    schema
    |> Ecto.Enum.mappings(field)
    |> Enum.find(fn {_atom, dump} -> dump == value end)
    |> case do
      {atom, _dump} ->
        atom

      nil ->
        raise ArgumentError,
              "#{inspect(value)} is not a valid dump value for #{inspect(schema)}.#{field}"
    end
  end
end
