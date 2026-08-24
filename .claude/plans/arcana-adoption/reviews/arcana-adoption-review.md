# Review: arcana-adoption (native reranking + code knowledge graph)

**Date:** 2026-08-18
**Verdict: REQUIRES CHANGES** — 3 BLOCKERs, 5 WARNINGs, suggestions.
**Detail:** full merged findings in `../summaries/review-consolidated.md`; per-agent
output in this directory (`elixir.md`, `security.md`, `testing.md`, `oban.md`,
`verification.md`, `requirements.md`).

## Requirements Coverage (plan: .claude/plans/arcana-adoption/plan.md)

**17 MET · 3 PARTIAL · 0 UNMET · 4 UNCLEAR.** The three PARTIALs are the known
dev-DB-blocked execution items (2.5 backfill run, 3.3 EXPLAIN, 4.3 live smoke) —
code verified present; execution artifacts pending Ben's migration+restart.
UNCLEARs are "Verify:" checklist lines not executable in the verifier's env.
No genuine UNMET. (Would be PASS WITH WARNINGS on requirements alone; the code
blockers below drive the verdict.)

## Verification

compile --warnings-as-errors ✓ · format ✓ · credo --strict ✓ · dialyzer 0 errors ✓
· sobelow ✓ · unit 276 ✓ · integration (NIF) 84 ✓

## BLOCKERs

1. **Unbounded edge fan-out in `related_code` traversal (memory DoS).**
   `graph.ex` `edges_query/4` has no LIMIT and the hop-2 frontier is uncapped;
   the 50-cap applies only after full traversal. `{"entity":"get","relation":
   "callers","hops":2}` on a hot symbol loads six-figure edge sets into the BEAM
   heap on a node already carrying the 1.2GB embedding model. Fix: `order_by
   weight desc, limit` inside `edges_query` + cap the hop-2 frontier.

2. **Concurrent `UpsertChunks` deadlock on entity/edge upserts.** Two jobs
   (queue concurrency 5) multi-row-upserting overlapping conflict keys in
   different orders deadlock in Postgres. Fix: sort every `insert_all` batch by
   its conflict-target tuple.

3. **Backfill TOCTOU race silently no-ops sources.** `force_full_resync_git_sources`
   clears the watermark, but an in-flight cron `RepoSync` (which the backfill's
   insert dedups onto via `unique`) re-writes its stale pre-clear cursor at
   completion — the full resync never happens and nothing reports it. Fix:
   optimistic cursor check in `advance_watermark` (re-fetch + conditional write)
   or backfill-side in-flight-job detection. **Must land before the backfill run.**

## WARNINGs

1. Partial kind-conversion clauses (`ref_entity_kind/1` etc.) + changeset-less
   graph writes will crash mid-transaction at the LLM-extractor seam — add
   catch-alls that raise `ArgumentError` + staged-row validation.
2. LIKE-metachar injection in `find_entities` suffix tier (`entity: "%"` walks
   the corpus; index-defeating patterns seq-scan) + no length bound on `entity`
   or `significant_terms/1` terms. Escape via `fragment("... ESCAPE '\\'")`
   (mirroring `bench/runner.ex` `like_pattern/1`), bound lengths.
3. The tree-sitter extractor's ONLY tests are `:integration`-tagged — default
   `mix test`/CI never runs them. Add a non-NIF smoke path or wire
   `--include integration` into CI deliberately.
4. Entity-leg trigram match is not source-scoped before the join — explicitly
   check this in the pending 3.3 EXPLAIN pass.
5. Graph-write hazards: verify `references[].from` is always file-local (edge
   delete-then-reinsert safety), `GraphGc` has no `timeout/1` despite an
   unbounded loop on a shared 5-slot queue, and pathological files stretch the
   UpsertChunks transaction (interacts with BLOCKER 2).

## SUGGESTIONS (grouped)

Shared `EctoEnum.from_dump!` helper; hoist graph test fixtures; compile-time
`@candidate_pool` type guard; truncate rerank *query* text + pin reranker model
revision; rerank scores length assertion; `--force`/confirmation gate on
`rn.graph.backfill`; thread repo/lang filters into `definition_snippets`;
clarify last-write-wins comment; make the `:limit` test assertion load-bearing.

## Notes

- Sobelow-skip claim in `hybrid_query.ex` **verified accurate** by the security
  pass (all runtime values are binds in both SQL variants).
- Scrub ordering **confirmed safe**: extraction consumes `redacted_content`.

---

## Addendum (same day): fixes applied

Ben approved "fix blockers + warnings now". All 3 BLOCKERs and warnings W1/W2/W3/W5
fixed and verified (W4 is folded into the pending 3.3 EXPLAIN pass by design):

- B1: `@edge_fanout_limit 500` (order-by-weight + LIMIT in edges_query) +
  `@hop2_frontier_limit 100`; frontier-cap test with deterministic weights.
- B2: all four graph insert_all sites sort by their conflict-target tuple
  BEFORE chunking into batches (`sort_by_conflict_key/2`).
- B3: `advance_watermark/2` is now an optimistic conditional update_all
  (`WHERE cursor = <cursor read at start>`); 0-rows → warn + skip advance
  (safe direction: next cron re-syncs from the newer/cleared cursor). Race test added.
- W1: ArgumentError catch-alls on kind conversions + enum-subset pin test.
- W2: LIKE-escape via `fragment(... ESCAPE '\\')` in the suffix tier,
  `@max_entity_bytes 256` on related_code, `@max_term_length 64` in
  significant_terms; corpus-walk (`entity: "%"`) test added.
- W3: ci.yml runs `mix rn.grammars.prefetch` + `--include integration` over
  graph/extractor + chunking.
- W5: one-source-per-batch ArgumentError guard in upsert_from_staged;
  GraphGc `timeout/1` 30min; `references[].from` file-locality confirmed +
  documented in the extractor moduledoc.

Post-fix verification: compile/format/credo/sobelow clean; full suite 286
passed; `--include integration` 309 passed. SUGGESTIONs remain open (listed
above) — none block merge.

**Updated verdict: PASS WITH WARNINGS** (open suggestions only; dev-DB
execution items still pending Ben's migration/restart).

---

## Addendum 2 (Aug 20): W4 resolved by the 3.3 EXPLAIN pass

W4 (entity-leg source-scoping) was validated on the fully-backfilled corpus and
led to a real restructure: the leg now pre-selects entities via the trigram
index in a bounded single-reference MATERIALIZED CTE (43ms vs 450-570ms), plus
stopword filtering in significant_terms/1 (grammar-word trigrams forced a 1.29s
seq scan). Corpus-wide pre-selection (no repo pushdown into entities) is
documented as a deliberate, bounded tradeoff. End-to-end graph-on cost: +71ms.
All suites/analyzers re-verified green (287 tests).
