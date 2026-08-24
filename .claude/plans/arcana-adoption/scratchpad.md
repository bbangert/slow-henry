# Scratchpad: arcana-adoption

Decisions log + dead ends. Plan: `plan.md`. Interview: `interview.md`.

## Decisions

- 2026-08-18: Approach B chosen (native build, Arcana as blueprint only). A = sidecar dep
  rejected for single-maintainer/3.0-churn risk + unconfirmed store fit; C = re-platform
  rejected (ingest can't be offloaded — Arcana has no git/incremental/Oban support).
- Reranker model: `cross-encoder/ms-marco-MiniLM-L-6-v2` — the only Bumblebee-loadable
  option (no XLM-RoBERTa/DeBERTa-v2/trust_remote_code in Bumblebee 0.7).
- Entity identity: `(source_id, language, qualified_name)` — 91 repos share generic names.
- Graph rows FK → `chunks.id ON DELETE CASCADE` (same pattern as secret_findings).
- LLM prose extraction deferred: corpus is 586,418 chunks, 100% git_repo (verified on
  5433, 2026-08-18). Behaviour seam only (Phase 5.1).

## Dead ends / rejected

- tree-sitter query API (.scm patterns): NIF doesn't execute queries, only returns raw
  query text. Manual walking required.
- bge-reranker-v2-m3 / jina-reranker-v2 / mxbai: architectures unsupported by Bumblebee.
- Separate graph staging table: rejected — thread through existing PendingChunks →
  UpsertChunks transaction instead.

## Gates pending

- [ ] Phase 0: `Bumblebee.Text.cross_encoding/3` present in locked version?
- [ ] Phase 1.4: rerank eval (MRR/Hit@1, p95 ≤ 300ms) → default on/off
- [ ] Phase 3.3: EXPLAIN ANALYZE — no plan regression from third leg
- [ ] Phase 2.5: backfill duration + mention counts at 586k chunks

## Phase 0 (2026-08-18)

- GATE PASS: `Bumblebee.Text.cross_encoding/3` present in locked bumblebee 0.7.0
  (`deps/bumblebee/lib/bumblebee/text/cross_encoding.ex`). Spike
  (`scratchpad/cross_encoding_spike.exs`): ms-marco-MiniLM-L-6-v2 loads as Bert
  :for_sequence_classification; scores {relevant 9.25, irrelevant -11.12}; 210ms
  batch-of-2 @ seq 256 under EXLA. No bumblebee bump; embedding tests green.
- ENV: port 5432 in this container is a dead port-forward (no owning process,
  connects but hangs). The only live cluster is PG 18.4 on **5433** (also holds
  the dev corpus). `mix test` / `mix ecto.*` need `PGPORT=5433`.
- cross_encoding tokenizer truncates pairs to `sequence_length` itself
  (`Bumblebee.configure(tokenizer, length: ...)`), so passage truncation is a
  cost/quality knob, not a correctness requirement.

## Phase 1.4 eval gate (2026-08-18) — DECISION: rerank_default stays FALSE

24 queries, top_k 10, real 5433 corpus, warmed servings, Oban paused:

| mode     | MRR   | Hit@1 | Hit@5 | p50    | p95    |
|----------|-------|-------|-------|--------|--------|
| baseline | 0.323 | 0.208 | 0.500 | 459ms  | 476ms  |
| reranked | 0.320 | 0.250 | 0.375 | 2178ms | 2794ms |

- Rerank does NOT win: MRR flat-to-worse, Hit@5 notably worse (ms-marco-MiniLM
  unvalidated-on-code concern confirmed); p95 ~9x over the 300ms budget —
  50 pairs @ seq-512 on CPU EXLA is ~1.7s of inference, far above the ~100ms
  literature estimate the research flagged as unverified.
- Feature stays shipped behind `rerank: true` opt-in (MCP + Search API); config
  default false. Re-run `PGPORT=5433 PORT=4009 mix rn.rerank_eval` if a
  code-tuned BERT-family reranker or GPU/EMLX backend lands later.
- Fun fact: rerank fixed 3 queries (docker-addons 3→1, recorder-purge 2→1,
  entity-registry 2→1) but tanked others (secrets-redaction 1→3, config-entries
  1→3) — it's not noise, it's genuinely mixed on code.

## Phase 2.2 extractor — empirical grammar quirks (verified on live NIF)

- go `type_declaration`: name lives on child `type_spec`, not the node. Special-cased.
- rust `impl_item`: no name field; uses `type:` field (impl'd type name).
- go receiver methods come out `:function` not `:method` (method_declaration is a
  top-level sibling of the type, never AST-nested — container rule can't fire).
- ruby paren-less zero-arg calls parse as bare `identifier`, not `call` — such calls
  are invisible to extraction (grammar limitation, documented best-effort).
- Anonymous defs (js arrows etc.) emit no entity; refs inside them scope to the
  nearest NAMED enclosing def.

## BLOCKER (2026-08-18): dev-DB ops need Ben

The auto-mode permission classifier denies mutating the 5433 dev corpus DB
(`mix ecto.migrate` and `mix run -e 'RetrievalNode.Release.migrate()'` both
blocked). Code for 2.5 is DONE (`mix rn.graph.backfill` + --status); blocked
on executing, in order:
  1. `PGPORT=5433 mix ecto.migrate`            (adds graph tables + staging col)
  2. restart dev server (PID was 42657) with new code:
     `PGPORT=5433 PORT=4001 elixir --sname slow_henry -S mix phx.server`
     (restart ALSO needed because my earlier `mix rn.rerank_eval` run called
     Oban.pause_all_queues() without local_only — it likely paused the dev
     server's queues cluster-wide; task since fixed to local_only: true)
  3. `PGPORT=5433 mix rn.graph.backfill` then monitor with --status
Downstream blocked items: 2.5 metrics, 3.3 EXPLAIN ANALYZE, 4.3 live smoke.

### HANDOFF: arcana-adoption (2026-08-18)
Status: 14/17 tasks done. All CODE complete and verified (full suite 276 passed,
format/credo/sobelow clean — one sobelow_skip added for the parameterized
hybrid-query SQL, mirroring runner.ex's marker style).
Blockers (all one root cause — dev-DB mutation denied by permission classifier):
  - 2.5 backfill execution + metrics
  - 3.3 EXPLAIN ANALYZE index verification
  - 4.3 live MCP smoke
Next (needs Ben, in order — see BLOCKER section above for exact commands):
  migrate 5433 → restart dev server (new code + clears my accidental global
  Oban pause) → `mix rn.graph.backfill` → --status until drained → 3.3 EXPLAIN
  (paste plans here) → 4.3 smoke via MCP HTTP on :4001.
Key decisions this session: rerank eval FAILED (default stays false, opt-in
kept); graph leg default false pending 3.3; entity qualified_name excludes file
path (plan's uniqueness key, best-effort merge documented); per-file edge
re-derivation (delete-then-insert) for idempotency.

## Review + fixes (2026-08-18)

/phx:review (6 agents): 3 BLOCKERs (related_code fan-out DoS, concurrent-upsert
deadlock, backfill watermark TOCTOU), 5 WARNINGs. All blockers + W1/W2/W3/W5
FIXED same session (see reviews/arcana-adoption-review.md addendum). W4
(entity-leg source-scoping) deliberately folded into the pending 3.3 EXPLAIN
pass. Post-fix: full suite 286, integration 309, all analyzers clean.
IMPORTANT for backfill: B3 fix (optimistic watermark) is a prerequisite that is
now in place — backfill is safe to run once Ben migrates + restarts.

## Backfill launched (2026-08-18 ~14:55 UTC)

- Ben ran the migration; old dev server (PID 42657, 12 days old, queues paused
  since my 04:45 eval) was NOT restarted — killed it (SIGTERM→SIGKILL; beam
  ignored TERM for 18s) and started a fresh `--sname slow_henry` on :4001 with
  new code. /healthz warm.
- `mix rn.graph.backfill`: **90 RepoSync jobs enqueued, watermarks cleared.**
- Persistent monitor polls every 5 min (30-min heartbeat, drain detection:
  entities>1000 && pending_chunks=0 && chunk/embed/upsert+sync queues idle,
  two consecutive checks). Record duration + counts here when drained.

- Backfill throughput @1.6h: 30,910 chunks upserted (~19k/h) → ~30h ETA for
  586k. Embed queue (concurrency 1) dominates; re-embeds are bit-identical
  (same model/content) — offered Ben an EmbedBatch content-hash short-circuit
  (copy existing embedding on match) as an optional accelerator.

## Backfill incident + hot-fix (2026-08-18 ~18:00)

- SYMPTOM: 2 upsert jobs discarded — `entities` composite unique btree index
  rejects rows > ~2,700 bytes (Postgres index-row limit); minified/generated
  files yield multi-KB "identifiers" (one was 18,440 bytes). A discarded
  UpsertChunks job loses ALL chunks of the file, not just graph rows.
- FIX (live-reloaded via touch + /healthz hit): `@max_symbol_bytes 256` —
  (a) extractor skips oversized defs/refs at emission (skip, not truncate:
  truncation would collide unrelated junk); (b) `Graph.sanitize_graph/1`
  consumer guard drops oversized names from ALREADY-STAGED rows with a
  warning (rescues the in-flight ~300k-row backlog). Tests added (extractor
  integration + pipeline sanitation). Full suite 287.
- Discarded jobs retried via SQL (Oban retry semantics) → both completed.
- Also fixed: RerankingTest async:true mutated global :reranking_impl →
  seed-dependent cross-test failure (RerankEvalTest). Now async: false.
- FALSE ALARMS during triage: 88 discarded sync jobs were Aug 15 (old server's
  DNS blip), not new; 30-min frozen graph counts = buildroot/C repos flowing
  (heuristic chunker, no tree-sitter langs → legitimately zero graph rows).

## 3.3 preliminary EXPLAIN (mid-backfill, 57k entities)

Entity leg standalone, terms ['recorder','purge'], unfiltered:
Bitmap Index Scan on entities_qualified_name_trgm_idx (Index Cond:
qualified_name %> ANY(...), Index Searches: 2) → Bitmap Heap (76 rows) →
index-only scans on entity_mentions unique idx + chunks_pkey. Execution 9.7ms.
NO seq scans. W4 (source-scoping) not yet a concern at this size — re-verify
at full size with filters + full 3-leg query after drain.

## Backfill complete + 3.3/4.3 verification (2026-08-20)

### 2.5 metrics
- Duration: 14:55 Aug 18 → 06:30 Aug 20 (~39.6h wall; embed queue @ concurrency 1
  was the bottleneck throughout, ~9-19k chunks/h depending on chunk-length mix).
- 90 sources, 595,014 chunks re-flowed (corpus grew ~9k during the run from live
  upstream commits). Zero failed jobs after the qualified_name hot-fix.
- Final graph: 227,530 entities / 1,052,247 mentions / 480,794 edges = 455MB
  incl. indexes (~13% of chunks' 3.5GB). DB total 4.5GB post-drain.
- Spot-checks: async_setup_entry → 3,837 definition mentions (one per HA core
  integration) + 84 caller edges. Top mentions: get(23k),
  async_block_till_done(16k), homeassistant.core(13k), patch(11k) — all sane.

### 3.3 EXPLAIN — gate caught TWO regressions at full scale, both fixed
1. Original joined-leg shape: planner drove chunks→mentions→entities evaluating
   `%>` + similarity per row (450-570ms, seq scan on entities when unfiltered).
   FIX: `entity_matches AS MATERIALIZED` single-reference CTE — trigram bitmap
   index pre-selects symbols, similarity computed only for matches, LIMIT 500,
   then join outward via index-only scans. 43ms. (Does NOT violate the
   shared-CTE law: referenced once, bounded, materialization deliberate.)
2. Stopword terms: "the" (one ubiquitous trigram) in `%> ANY` made the planner
   seq-scan (1.29s). FIX: conservative English stopword list in
   significant_terms/1 (grammar words only — get/set/run/all NOT listed).
- Review W4 (source-scoping): resolved-by-documentation — pre-selection is
  corpus-wide by design (entities have no repo column); filtered starvation is
  bounded by pool 500 and the leg being additive. Comment in @entity_matches_sql.
- Final plans: trigram bitmap (Index Cond: qualified_name %> ANY) + index-only
  mention/chunk scans; vector leg on HNSW; FTS on GIN. No materialization
  regression on the two-leg query (byte-identical SQL when graph off).

### 4.3 live smoke (streamable_http, :4001, session transcript)
- initialize → notifications/initialized → tools/call: OK.
- semantic_search "how does the recorder purge old history..." repo=core:
  plain 455ms; graph:true 526ms (+71ms; recorder/purge.py defs + test callers
  surface); rerank:true 2.2s (matches eval; opt-in as gated).
- related_code entity=purge_old_data relation=callers repo=core: returns
  caller definitions with real snippets (test_purge.py etc.).
- /healthz all-ok throughout.

### Config decision
- graph_leg_default stays FALSE (plan gave no relevance gate for flipping it;
  latency is now proven fine at +71ms, so flipping is a one-line config change
  once a relevance eval — analogous to rerank's 1.4 — says the leg helps).

## Review r2 + fixes (2026-08-21..24)

Second-pass review (6 agents, delta focus): r1 fixes all verified genuine;
found W-r2-1 language-binding bug in resolve_entity_ids (qualified_name-only
key; cross-language same-name collision binds mentions to wrong entity).
Fixed: language-filtered select-back + batch-lang guard; also sanitize_graph
shape validation, write_edges shared sort, coverage gaps. Full suite 296.
Backfill data impact: 5,123 wrong-lang mentions (0.5%), 292 entities,
10 sources; 3,313 rebindable by SQL. Repair options: (a) surgical SQL
rebind+delete (edges imprecision ~0.5% remains, heals on churn), (b) accept +
heal-over-time, (c) re-sync the 10 sources. Awaiting Ben.

## Graph data repair (2026-08-24) — COMPLETE

Surgical SQL transaction on 5433 (Ben-approved): 3,313 wrong-language mentions
rebound to correct-language entities; 1,810 with no correct entity deleted
(re-derive on next file change); 4,876 cross-language edges deleted (extractor
can never legitimately produce cross-language edges — all bug artifacts).
Post-repair verification: 0 wrong mentions, 0 cross-language edges. Orphaned
entities reaped by nightly GraphGc. Note: uuid pk needs ::text for min() in
such repair scripts.
