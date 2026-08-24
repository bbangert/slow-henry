# Review r2: arcana-adoption (second pass, post-fix delta)

**Date:** 2026-08-21
**Verdict: REQUIRES CHANGES** — 1 data-integrity warning that must land before merge;
everything from review r1 verified genuinely fixed.
**Per-agent output:** `{elixir,security,oban,testing,verification,requirements}-r2.md`
in this directory.

## Requirements Coverage

**24 MET · 0 PARTIAL · 0 UNMET · 1 UNCLEAR.** All three r1 PARTIALs (backfill,
EXPLAIN, smoke) verified executed with internally consistent evidence. The one
UNCLEAR: risk-register #4's "graph extraction adds <20% ingest overhead" was
never explicitly isolated against a pre-graph baseline (embed-queue dominance
makes it true by construction, but unmeasured).

## Verification

compile ✓ · format ✓ · credo (835 mods/funs) ✓ · full suite 287/287 under TWO
seeds (no order-dependent pollution) ✓ · integration 311 ✓ · sobelow ✓ ·
dialyzer skipped (no cached PLT this run; passed in r1).

## Prior-fix verification (all six r1 blockers/warnings)

- Fan-out DoS: FIXED — both hops bounded (500-row LIMIT + 100-id frontier).
- Upsert deadlock: FIXED — sort-before-chunk holds across batch boundaries on
  all four insert paths.
- Watermark TOCTOU: FIXED — optimistic update sound (Postgres jsonb `=` is
  normalized; key-order false-mismatch is a non-issue); race test is genuine.
- LIKE escaping / length bounds / CI integration step: FIXED and complete.
- sobelow_skip claim re-traced and still accurate after the leg restructure.
- GraphGc timeout retry-safe (GC loop is separate auto-committed deletes).

## MUST FIX (drives the verdict)

**W-r2-1 — `resolve_entity_ids/3` drops `language` from the binding key**
(`graph.ex` ~605-610). The select-back that maps names → entity ids filters by
source_id + qualified_name only, and the map is keyed by qualified_name alone —
but entity identity is `(source_id, language, qualified_name)`. A name defined
in two languages of one source (`setup` in Python and JS — common) returns both
rows; last-wins keying then binds mentions/edges to the wrong-language entity.
Silent data corruption, no crash. Fix: batches are per-file (uniform
`row.lang`), so filter the select-back by language and/or key the map by
`{language, qualified_name}`.

## SHOULD FIX (cheap, latent)

- **W-r2-2** `sanitize_graph/1` validates size but not shape: a `null`
  qualified_name (key present → Map.get default skipped → `byte_size(nil)`
  raises), a non-map list element, or a missing key downstream all roll back
  the Multi and can discard the file after max_attempts — the exact failure
  class the sanitizer exists to prevent. Latent until a non-tree-sitter
  producer (LLM seam) exists. Filter non-binary names in the same pass.
- **W-r2-3** `write_edges/2` inline-sorts instead of using shared
  `sort_by_conflict_key/2` (drift trap).
- **W-r2-4** Tests: `@stopwords` branch of `significant_terms/1` has zero
  direct coverage (it's the fix behind the 1.29s→43ms win); `sanitize_graph`
  one-key/non-list cases untested. Persistent from r1: `:call`-weight
  three-way ordering, `hops` invalid-value + `lang` filter negative tests.

## SUGGESTIONS (grouped, non-blocking)

Hoist `@max_symbol_bytes` to one shared constant (extractor + consumer declare
it independently); deterministic tie-break (`, id`) on the two ORDER BY…LIMIT
cutoffs; `statement_timeout` on graph-read queries (hot-symbol in-degree is
bounded-memory but unbounded-CPU); backfill `--force` confirmation (persistent);
truncate the rerank *query* text (persistent, search.ex:102); per-row
sanitizer warnings could flood logs inside the transaction — aggregate to one
line per file; backfill boot could also disable `mcp_server_start`;
`pause_all_queues` in the backfill task is redundant given `queues: []` (comment
overstates); GraphGc discard has no alerting.

## Notes

- Backfill task `Application.put_env` confirmed node-local — no cross-node leak.
- `escape_like/1` regex verified to emit correct `\`-escapes; all three
  `find_entities` tiers safe.

---

## Addendum (fixes applied)

Ben approved must+should. W-r2-1..4 all fixed and verified (full suite 296,
credo/sobelow clean): language-scoped `resolve_entity_ids/4` (+ per-batch lang
guard tolerant of graph-empty rows), shape validation in `sanitize_graph/1`
(non-map/nil-name elements dropped, downstream fetch! safe by construction),
`write_edges/2` on the shared sort helper, and the missing tests (stopword
branch, 3-way kind ordering, hops/lang negatives, sanitizer edge cases).

Backfilled-data impact of W-r2-1 measured on 5433: 5,123 wrong-language
mentions (~0.5% of 1.05M) across 292 entities in 10 sources; 3,313 rebattachable
to an existing correct-language entity via SQL. Repair decision → Ben.

Data repair EXECUTED 2026-08-24 (Ben-approved surgical SQL): 3,313 rebound,
1,810 deleted (heal on churn), 4,876 cross-language edge artifacts deleted;
post-repair checks zero in both dimensions.

**Updated verdict: PASS WITH WARNINGS** (open suggestions only).
