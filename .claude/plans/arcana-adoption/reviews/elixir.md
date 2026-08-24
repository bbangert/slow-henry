# Elixir Review: arcana-adoption (reranking + code knowledge graph)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 7 (0 blocker, 4 warning, 3 suggestion)

Overall the new subsystems (`Reranking.*`, `Graph.*`, `HybridQuery` graph leg,
`ChunkFiles`/`UpsertChunks` graph wiring) are unusually well-documented and
mostly idiomatic — moduledocs explain load-bearing OTP/SQL decisions rather
than just restating code. No correctness/data-loss blockers found. Findings
below are edge cases and doc-accuracy nits.

## Warnings

1. **`lib/retrieval_node/graph.ex:453-454,608-609,566-567`** — `ref_entity_kind/1`,
   `edge_kind/1`, `mention_kind/1` are partial functions covering only
   `"call"`/`"import"`. This is currently safe because `ChunkFiles.reference_attrs/1`
   (`lib/retrieval_node/ingest/workers/chunk_files.ex:190-191`) only ever emits
   `ref.kind` as `:call`/`:import` per `Extractor.TreeSitter`'s two reference
   kinds — but nothing enforces that invariant at the `Graph.upsert_from_staged/3`
   boundary. Since `graph` jsonb is untyped storage, a future extractor (e.g.
   the LLM impl once implemented) that emits a third ref kind will raise
   `FunctionClauseError` deep inside an `Ecto.Multi.run` step, inside the
   `UpsertChunks` transaction — an ingest-wide crash instead of a clear error.
   Fix: add a catch-all clause that raises `ArgumentError` with the bad value
   (same "fail loud with a clear message" pattern already used in `kind_atom/2`
   and `UpsertChunks.to_enum/2`), so the failure mode is at least legible.

2. **`lib/retrieval_node/graph/extractor/tree_sitter.ex:453-454`** — `Extractor.TreeSitter`
   validates none of `entity.kind` against `Graph.Entity`'s `Ecto.Enum` allowlist
   at extraction time; `entity_kind_for/2` only ever returns the 4 known atoms so
   this is safe today, but `definition_attrs/2` in `graph.ex:410` calls
   `kind_atom(Entity, :kind, Map.fetch!(entity, "kind"))` — a string round-trip
   through jsonb that will raise on any drift between the extractor's kind atoms
   and `Entity`'s enum values. No test currently pins that these two lists
   (`entity_kind_for/2`'s outputs vs. `Entity.kind`'s `values:`) stay in sync;
   worth a compile-time or test-level assertion.

3. **`lib/retrieval_node/graph.ex:611-624` (`write_edges/2`)** — Known/documented
   best-effort gap (edges from a from-entity are wholly replaced by
   `delete_all` + reinsert per ingest of *that entity's own file*), but the
   `delete_all` scope is `source_entity_ids` — all distinct source entities touched
   by *this batch's* references, not scoped to the current `source_id`. Since
   entity ids are already source-scoped (via `resolve_entity_ids/3`'s
   `where: e.source_id == ^source_id`), this is fine in practice (a batch is one
   source), but there's no assertion that `staged_rows` truly all share one
   `source_id` beyond the moduledoc comment — a caller violation would silently
   delete/rewrite edges for entities beyond the intended file. Consider a guard
   (`Enum.uniq_by(staged_rows, & &1.source_id) |> length() == 1` in a dev/test
   assertion, or a raise) given how load-bearing this assumption is for
   `write_edges/2`'s correctness.

4. **`lib/retrieval_node/search/hybrid_query.ex:159-183` (entity leg)** — The
   trigram match `e.qualified_name %> ANY($9::text[])` is NOT scoped by
   `source_id`/`repo` before the `JOIN chunks c` — filtering happens only via
   `@filters_c` on `c.*` after the three-way join. For a large multi-repo corpus
   this means the entity-name trigram scan runs unfiltered across every source's
   entities before the chunk-level filter narrows it down, unlike the vector/FTS
   legs which filter `chunks` directly in their own `WHERE`. This is consistent
   with the "pending EXPLAIN validation" caveat already called out in the
   moduledoc/plan, so not re-litigating the decision to ship it off-by-default —
   flagging so the eventual EXPLAIN pass specifically checks whether pushing
   `c.source_id`/`repo` into the `entities`/`entity_mentions` join order (rather
   than only the outer `chunks` filter) is needed once `graph_leg_default` is
   reconsidered.

## Suggestions

1. **`lib/retrieval_node/graph.ex:664-676`, `lib/retrieval_node/ingest/workers/upsert_chunks.ex:125-141`** —
   `kind_atom/2` and `to_enum/2` are near-identical (linear scan of
   `Ecto.Enum.mappings/2` + raise on miss). Consider extracting a shared helper
   (e.g. `RetrievalNode.EctoEnum.from_dump!/3`) since the same pattern will
   likely recur for the next Ecto.Enum-backed staging round-trip.

2. **`lib/retrieval_node/graph.ex:390-403` (`collect_definitions/1`)** — comment
   says "Last write wins for an (unexpected) duplicate key within this batch,"
   but `Map.put/3` in a `Enum.reduce/3` over a list built with `Enum.flat_map`
   (which preserves row order) means *last* here is whatever `staged_rows`'
   iteration order happens to be — worth a one-line note that this depends on
   `staged_rows` order rather than being an inherent last-wins-by-timestamp
   guarantee, in case a future caller reorders rows before calling
   `upsert_from_staged/3`.

3. **`lib/retrieval_node/reranking/nx_serving_impl.ex:41-43`** — `rerank_scores/2`
   asserts (comment only, not enforced) that the serving always returns a list
   the same length/order as `pairs`. A single defensive `length(scores) ==
   length(passages)` check (or trusting `Nx.Serving`'s contract entirely and
   removing the comment) would remove ambiguity — currently the comment reads
   like a runtime guarantee but nothing checks it, so a serving-contract
   regression silently misaligns scores to passages.

## Pre-existing (unchanged files, not deep-reviewed)
(none flagged — all issues above are in files under review per the diff list)
