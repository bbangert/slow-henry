## Requirements Coverage (from .claude/plans/arcana-adoption/plan.md) — R2 (delta re-check)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 0.1 | Verify bumblebee `cross_encoding/3` support, gate | MET | `lib/retrieval_node/reranking/nx_serving_impl.ex`; embedding path untouched in diff |
| 1.1 | Reranking serving, supervised, test-disabled, truncation | MET | `lib/retrieval_node/reranking/{serving,supervisor,warmer,nx_serving_impl}.ex`; `nx_serving_impl.ex` `truncate_passage/1` |
| 1.2 | Wire rerank into search, top-50 pool, `rerank` opt, preserve scores | MET | `lib/retrieval_node/search.ex` `hybrid_search/2` (deviation from `semantic/2`, documented in plan) |
| 1.3 | MCP `semantic_search` `rerank` field | MET | `lib/retrieval_node/mcp/tools/semantic_search.ex:32,53,87-88` |
| 1.4 | Eval gate ≥20 pairs, MRR/Hit@k, latency, decision | MET | `lib/retrieval_node/bench/rerank_eval.ex`, `priv/bench/queries.jsonl` (24 lines), `config/config.exs:101` `rerank_default: false`; scratchpad:46 "Phase 1.4 eval gate — DECISION: rerank_default stays FALSE" matches gate-failed numbers in plan (MRR 0.320 vs 0.323, p95 2794ms) |
| 2.1 | Graph migration: tables, cascades, uniques, trigram GIN | MET | `priv/repo/migrations/20260714140001_create_graph_tables.exs` |
| 2.2 | `Graph.Extractor` behaviour + TreeSitter, single-parse reuse | MET | `lib/retrieval_node/graph/extractor.ex`, `.../extractor/tree_sitter.ex`, `chunking.ex` `chunk_with_graph/2` |
| 2.3 | Persistence staged through PendingChunks→UpsertChunks, batching | MET | `priv/repo/migrations/20260714140002_add_graph_to_pending_chunks.exs`; `lib/retrieval_node/graph.ex` `upsert_from_staged/3`; `upsert_chunks.ex` same Multi |
| 2.4 | Cascade test + periodic GC | MET | `test/retrieval_node/graph/graph_test.exs`; `lib/retrieval_node/ingest/workers/graph_gc.ex` |
| 2.5 | Backfill executed on 5433, duration/counts recorded | MET (upgraded from PARTIAL) | `lib/mix/tasks/rn.graph.backfill.ex`; scratchpad:163-174 "Backfill complete" — 90 sources, 14:55 Aug18→06:30 Aug20 (~39.6h), 595,014 chunks, 227,530 entities/1,052,247 mentions/480,794 edges (455MB), spot-check `async_setup_entry` 3,837 mentions/84 edges — matches plan's 2.5 note verbatim, internally consistent (chunk/entity/mention counts scale plausibly: ~4.6 mentions/entity, ~0.8 chunks/entity) |
| 2.5-verify | Full suite + psql spot-checks | MET | scratchpad:172-174 spot-check numbers cited above; plan's own verify line claims 287 passed |
| 3.1 | `entity_search` CTE, trigram, mention-kind weighting, RRF | MET | `lib/retrieval_node/search/hybrid_query.ex` `entity_matches`/RRF weighted sum |
| 3.2 | Config weight, env-tunable, conservative default | MET | `config/config.exs:107` `graph_leg_default: false, graph_leg_weight: 0.5` |
| 3.3 | EXPLAIN ANALYZE index verification on 5433 | MET (upgraded from PARTIAL) | scratchpad:176-191 records two regressions found+fixed at full scale (seq-scan on entities 450-570ms → MATERIALIZED single-ref CTE 43ms; stopword "the" forcing 1.29s seq scan → stopword filter added); code confirms fix present: `hybrid_query.ex` `@entity_matches_sql` uses `MATERIALIZED` (line ~203), `@stopwords` MapSet (line 82) referenced in `significant_terms/1` (line 356-363) |
| 3.3-verify | Full suite + latency comparison | MET | scratchpad:196-197 live MCP timing 455ms graph-off vs 526ms graph-on (repo-filtered, warm) — matches plan's verify line |
| 4.1 | `related_code` MCP tool | MET | `lib/retrieval_node/mcp/tools/related_code.ex` |
| 4.2 | `semantic_search` `graph` boolean opt | MET | `lib/retrieval_node/mcp/tools/semantic_search.ex` |
| 4.3 | Live smoke via MCP HTTP, transcript recorded | MET (upgraded from PARTIAL) | scratchpad:193-200 "4.3 live smoke" — initialize/tools-call OK; semantic_search plain 455ms, graph:true 526ms, rerank:true 2.2s (matches 1.4 eval magnitude); related_code entity=purge_old_data/relation=callers returns real snippets; /healthz all-ok — consistent with plan's verify claim (287 passed, healthz all-ok) |
| 4.3-verify | Full suite + `/healthz` green | MET | scratchpad:200 "`/healthz` all-ok throughout" |
| 5.1 | `Graph.Extractor.LLM` stub | MET | `lib/retrieval_node/graph/extractor/llm.ex` |
| Risk: PR #14 param-limit batching lessons applied to graph persistence | MET | `lib/retrieval_node/graph.ex` batch size constant tied to same precedent as `upsert_chunks.ex` |
| Risk: cascade FKs from chunks.id extended to graph tables | MET | migration `20260714140001` — all FKs `on_delete: :delete_all` |
| Risk #2: EXPLAIN ANALYZE mandatory gate before merge (self-check item) | MET | directly evidenced by scratchpad 3.3 section — the gate actually caught 2 real regressions, not a rubber-stamp |
| Risk #4: measure ingest slowdown in 2.5, reconsider if >20% | UNCLEAR | scratchpad:163-174 gives backfill wall-clock (~39.6h) but does not isolate/quantify graph-extraction overhead vs. baseline embed-queue-bound ingest to confirm <20% slowdown; states embed queue concurrency 1 was "the bottleneck throughout" implying overhead was absorbed, but no explicit before/after ingest-rate comparison is cited |

**Summary**: 24 MET · 0 PARTIAL · 0 UNMET · 1 UNCLEAR

**Delta from prior review** (`.claude/plans/arcana-adoption/reviews/requirements.md`): all 3 prior PARTIALs (2.5 backfill, 3.3 EXPLAIN, 4.3 smoke) are now MET — scratchpad section "Backfill complete + 3.3/4.3 verification (2026-08-20)" contains concrete metrics/plans/transcript that are internally consistent with each other and with the code (MATERIALIZED CTE and stopword list both present in `hybrid_query.ex`; latency figures for graph-on/off and rerank-on match magnitudes reported in the 1.4 eval gate). One new UNCLEAR surfaced on this pass: risk-register item #4 (ingest slowdown <20% threshold) was never explicitly measured/reported, only implied.
