# Plan: Native reranking + code knowledge graph (Arcana as blueprint)

**Slug:** arcana-adoption
**Date:** 2026-08-18
**Depth:** deep
**Decision:** Approach B from `interview.md` — build natively, no Arcana dependency.
Research: `research/{codebase-scan,arcana-deep-dive,reranker-models,native-graph-feasibility}.md`

## Goal

Add the two capabilities the MCP node lacks — cross-encoder reranking and a code
knowledge graph with graph-fused retrieval — implemented natively against the existing
schema, plus new MCP tools. Query path stays 100% local (no LLM at query time).

## Key facts constraining the design

- Corpus (PG 5433, `retrieval_node_dev`): **586,418 chunks, 100% `git_repo`** — zero
  jira/drive chunks exist. LLM prose extraction is a seam, not a build item (Phase 5, deferred).
- Only Bumblebee-loadable reranker: **`cross-encoder/ms-marco-MiniLM-L-6-v2`** (BERT
  `:for_sequence_classification`; bge/jina/mxbai architectures unsupported). First-party
  path: `Bumblebee.Text.cross_encoding/3` (added by bumblebee PR #444 — **verify present
  in our locked version before anything else**). 512-token pair limit ⇒ chunk truncation.
  Unvalidated on code ⇒ eval gate before default-on.
- `tree_sitter_language_pack` has **no query API** — manual AST walking only. Chunking's
  walk skips function bodies, so extraction needs a full traversal, but must **reuse the
  same parsed tree** (parse is the expensive, crash-guarded step).
- Verified node kinds (7 langs): python `call`/`import_statement`; JS/TS
  `call_expression`/`import_statement`; go `call_expression`/`import_declaration`; rust
  `call_expression`/`use_declaration`; ruby `call` only (`require` is a call, no import
  node); java `method_invocation`/`import_declaration`.
- Deletion is path-based on `chunks` (`repo_sync.ex:95-105`); `secret_findings` already
  FK-cascades from `chunks.id` ⇒ graph rows FK `chunks.id ON DELETE CASCADE`.
- `hybrid_query.ex` requires per-CTE-leg inlined filters to keep HNSW/GIN pushdown —
  third leg must follow the same shape; verify with `EXPLAIN ANALYZE` on 5433.
- `pg_trgm` already enabled; entity uniqueness key: `(source_id, language, qualified_name)`.
- Oban batching must respect the Postgres param-limit lessons from PR #14.

---

## Phase 0 — Spike: cross_encoding availability (blocking gate)

- [x] 0.1 [elixir] Check locked bumblebee version supports `Bumblebee.Text.cross_encoding/3`
      with `ms-marco-MiniLM-L-6-v2` (one-off script in scratchpad; load model, score 2 pairs).
      If absent: bump `{:bumblebee, ...}` and re-verify embedding serving still works
      (nomic-embed-text-v1.5 Matryoshka truncation at `nx_serving_impl.ex:85-90` untouched).
      — PASS on locked bumblebee 0.7.0: loads as Bert :for_sequence_classification,
      relevant pair 9.25 vs irrelevant -11.12, 210ms batch-of-2 @ seq 256 EXLA. No bump needed.
- [x] Verify: `mix compile --warnings-as-errors && mix test test/retrieval_node/embedding`
      — 12 passed, 2 excluded (integration). NOTE: tests need `PGPORT=5433` in this container
      (5432 is a dead forwarded listener; only cluster is on 5433).

## Phase 1 — Cross-encoder reranker

- [x] 1.1 [otp] `RetrievalNode.Reranking` serving: new `lib/retrieval_node/reranking/`
      following `embedding/` structure (behaviour + `NxServingImpl` + test stub impl).
      `Nx.Serving` for `cross_encoding`, batched, supervised in `application.ex` next to
      the embedding serving; config-disabled in `:test` env. Truncate passage text to fit
      512-token pair budget (reserve query tokens; document strategy in module doc).
      — Done: `lib/retrieval_node/reranking/{serving,supervisor,warmer,nx_serving_impl}.ex` +
      `reranking.ex` behaviour, StubImpl in test/support, gated by `:reranking_serving_start`
      (off in :test). Passage cap 2,000 bytes codepoint-safe (`truncate_passage/1`);
      tokenizer truncates pairs to seq buckets [256,512] anyway. 12 tests.
- [x] 1.2 [elixir] Wire into `Search.semantic/2` (`search.ex`): fetch top-50 from
      `HybridQuery`, rerank, return top-`limit`. New opts: `rerank: boolean`
      (config default, initially `false` until 1.4 passes), preserve existing scores in
      result metadata for eval comparison.
      — Done in `Search.hybrid_search/2` (plan said `semantic/2`; actual entry point).
      Funnel: top max(50, top_k) from HybridQuery → one content fetch → rerank → top_k.
      Rerank hits carry `score` (logit) + `fused_score` (RRF); shape unchanged when off.
      Config: `rerank_default: false`, `rerank_candidates: 50`.
- [x] 1.3 [elixir] MCP `semantic_search` tool: optional `rerank` boolean field, plumbed
      through; tool description updated.
      — Done: `field(:rerank, :boolean)`, nil omitted so config default applies;
      `fused_score` included in JSON only on rerank path. 24 search+mcp tests green.
- [x] 1.4 [elixir] Eval gate: bench script under `lib/retrieval_node/bench/` — ≥20
      query→expected-chunk pairs against the 5433 corpus; report MRR/Hit@1/Hit@5 and
      p50/p95 latency with and without rerank. **Decision recorded in scratchpad: flip
      config default to `true` only if reranked wins and p95 ≤ 300ms.**
      — Done: `Bench.RerankEval` + `mix rn.rerank_eval` + MRR/Hit@k metrics; queries.jsonl
      grown 15→24 (core/esphome/supervisor/hass-nabucasa targets). GATE FAILED: reranked
      MRR 0.320 vs 0.323, Hit@5 0.375 vs 0.500, p95 2794ms ≫ 300ms. Default stays false.
- [x] Verify: `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test` — 226 passed at phase end

## Phase 2 — Graph schema + tree-sitter extraction

- [x] 2.1 [ecto] Migration: `entities` (`source_id` FK, `language`, `qualified_name`,
      `kind` def-enum: function|method|class|module, `path`, `metadata` jsonb;
      UNIQUE `(source_id, language, qualified_name)`; `gin_trgm_ops` index on
      `qualified_name`), `entity_mentions` (`entity_id` FK, `chunk_id` FK
      **ON DELETE CASCADE**, `kind`: definition|call|import; UNIQUE
      `(entity_id, chunk_id, kind)`), `entity_edges` (`source_entity_id`,
      `target_entity_id`, `kind`: calls|imports, `weight` integer; UNIQUE triple).
      Ecto schemas in `lib/retrieval_node/graph/`.
      — Done: migration `20260714140001_create_graph_tables.exs` (binary_id PKs, all FKs
      CASCADE, trigram GIN via execute); schemas Entity/EntityMention/EntityEdge. Cascade
      pre-verified in schema_test (6 tests). Rollback round-trips.
- [x] 2.2 [elixir] `Graph.Extractor` behaviour (`extract(parsed_tree_or_text, lang, opts) →
      {:ok, %{entities: [...], references: [...]}}` — mirrors Arcana's GraphExtractor
      shape) + `Graph.Extractor.TreeSitter` impl: full-tree walk reusing the already-parsed
      root from chunking (extend `TreeSitterImpl.chunk/2` return to carry entities+refs —
      one parse, two consumers). Per-language node-kind maps from feasibility research;
      ruby: treat `require`/`require_relative` call nodes as imports. Qualified names use
      the existing container-breadcrumb logic.
      — Done: `Graph.Extractor` behaviour + `Extractor.TreeSitter` (full-tree walk, {root,
      source} input, 10k-item cap); `Chunking.chunk_with_graph/2` optional callback +
      dispatcher (heuristic impl → empty graph); TreeSitterImpl shares ONE parser_parse via
      parse_root/2, chunk/2 byte-identical. 64 tests incl. --include integration (real NIF).
- [x] 2.3 [ecto] Persistence: thread entities/refs through `PendingChunks` staging into
      the `UpsertChunks` transaction (same batch, param-limit-aware chunking per PR #14).
      Resolution: upsert entities → upsert mentions keyed by chunk → aggregate
      `entity_edges` weights (def-site → call-site edges within source; cross-source
      resolution by `qualified_name` match, best-effort).
      — Done: staging column `pending_chunks.graph` jsonb (migration 20260714140002, keeps
      graph out of chunk metadata); ChunkFiles → chunk_with_graph + line-containment
      attachment (unmatched → first chunk); `Graph.upsert_from_staged/3` in UpsertChunks'
      Multi (def entities replace-win, ref-only :nothing, delete-stale-mentions-then-insert,
      per-from-entity edge re-derivation, 2k batching). Fixed cold-boot function_exported?
      bug in dispatcher (needs Code.ensure_loaded?). Full suite 234 green.
- [x] 2.4 [elixir] Lifecycle: confirm cascade covers file deletion (test); add periodic
      GC (Oban cron or piggyback on existing maintenance) deleting entities with zero
      mentions. Note: inherits the pre-existing orphaned-chunk gap on intra-file boundary
      shifts — document, don't fix here.
      — Done: cascade-on-path-delete test (mirrors delete_removed/2);
      `Graph.gc_orphaned_entities/1` batched-loop GC + `GraphGc` Oban worker (queue
      :upsert, daily cron 04:30); orphaned-chunk gap documented in worker moduledoc.
- [x] 2.5 [oban] Backfill: mix task or admin function forcing full re-sync of all 91
      sources through the existing 4-stage pipeline (extraction now rides ChunkFiles→
      UpsertChunks). Run against 5433; record duration + row counts in scratchpad.
      — Done: 90 sources, ~39.6h wall (14:55 Aug 18 → 06:30 Aug 20), 595,014 chunks
      re-flowed. Final graph: 227,530 entities / 1,052,247 mentions / 480,794 edges
      (455MB incl. indexes; DB 4.5GB). One corpus-scale bug found+fixed mid-run
      (oversized qualified_name vs btree index-row limit — see scratchpad).
- [x] Verify: full suite + `psql -p 5433` spot-checks (entity counts for a known repo,
      e.g. does `async_setup_entry` exist with callers?)
      — 287 passed; `async_setup_entry`: 3,837 definition mentions, 84 caller edges.

## Phase 3 — Graph-fused retrieval

- [x] 3.1 [ecto] Third CTE leg in `hybrid_query.ex`: `entity_search` — trigram match of
      query terms against `entities.qualified_name`, join `entity_mentions` → chunk_ids,
      score by similarity × mention-kind weight, union into RRF `fused` (k=60). Filters
      (repo/lang/source) inlined into this leg exactly like the existing two.
      — Done: `entity_search` CTE — `qualified_name %> ANY($9)` (indexed word-similarity,
      terms via `significant_terms/1`: split, ≥3 chars, dedup, cap 8), mention-kind CASE
      weights (def 1.0 / call 0.6 / import 0.3), GROUP BY chunk MAX(score), weighted 3-way
      RRF (`SUM(weight/(k+rank))`, entity leg weight $10). Two-leg SQL byte-identical when
      graph off or terms empty. 17 search tests.
- [x] 3.2 [elixir] Config weight for the graph leg (env-tunable; default conservative).
- [x] 3.3 [ecto] Index verification: `EXPLAIN (ANALYZE, BUFFERS)` on 5433 for
      representative queries with/without filters — HNSW + GIN + trigram all hit, no CTE
      materialization regression. Paste plans into scratchpad.
      — Done, and the gate CAUGHT two regressions at full scale (fixed): the joined
      leg shape seq-scanned entities (450-570ms → restructured to entities-first
      MATERIALIZED single-ref CTE, 43ms), and stopword terms ("the") forced a 1.29s
      parallel seq scan (→ stopword filter in significant_terms/1). Final: trigram
      bitmap + index-only scans throughout; graph-on adds ~71ms end-to-end.
- [x] Verify: full suite + latency comparison — live MCP timing: 455ms graph-off vs 526ms graph-on (repo-filtered, warm).

## Phase 4 — MCP tools

- [x] 4.1 [elixir] `related_code` tool (`lib/retrieval_node/mcp/tools/related_code.ex` +
      one `component` line in `server.ex`): fields `entity` (required), `repo`, `lang`,
      `relation` (callers|callees|imports|importers|definitions), `hops` (1-2, default 1).
      Returns entities + definition-chunk snippets with repo/path/line provenance.
      — Done: Graph context read side (`find_entities` exact>suffix>trigram,
      `related_entities` 1-2 hops by edge weight, `definition_snippets` 20-line/1000-char
      truncation); tool validates relation/hops, empty result ≠ error.
- [x] 4.2 [elixir] `semantic_search`: `graph` boolean opt (fusion leg on/off), default from
      config; description updated so agent consumers discover both new capabilities.
- [x] 4.3 [elixir] Live smoke: run the node (`PGPORT=5433 PORT=4001 elixir --sname
      slow_henry -S mix phx.server`), exercise `related_code` + reranked `semantic_search`
      via MCP HTTP transport; record transcript in scratchpad.
      — Done over streamable_http on :4001: semantic_search (plain/graph/rerank) and
      related_code (callers of purge_old_data, real snippets) all green; transcript
      summary in scratchpad.
- [x] Verify: full suite + `/healthz` green. — 287 passed; healthz all-ok on the live node.

## Phase 5 — Deferred (explicit non-goals now)

- [x] 5.1 LLM prose extractor: only the `Graph.Extractor.LLM` stub module implementing the
      behaviour with `{:error, :not_configured}` + moduledoc pointing at the Req/Finch
      pattern in `jira.ex`. Build for real when jira/drive sources exist (corpus is 0% prose today).
  — Done: `Graph.Extractor.LLM` stub returning `{:error, :not_configured}`, moduledoc points
  at the Req/Finch pattern.
- Deferred entirely: Leiden/community detection, grounding/NLI, LiveView dashboard,
  `ask` synthesis (violates local-query-path constraint).

## Risks & self-check

1. **What breaks if I'm wrong about cross_encoding?** Phase 0 gates everything in Phase 1;
   worst case is a bumblebee bump, isolated by the embedding regression test.
2. **What's the most likely silent failure?** The third RRF leg de-optimizing the tuned
   query plan — hence mandatory EXPLAIN ANALYZE (3.3) before merge, mirroring how the
   original tuning was validated (`pg_stat_user_indexes`).
3. **What's irreversible?** Nothing — new tables are additive; reranking and graph fusion
   ship behind config flags defaulting off until their eval gates pass. Backfill re-sync
   is idempotent (`chunk_key`/`content_hash`).
4. Scale risk: 586k chunks ⇒ plausibly 2–5M mentions; UNIQUE indexes + batched upserts
   sized for that; measure ingest slowdown in 2.5 and reconsider edge aggregation if >20%.
5. Reranker may not help on code (no public evidence either way) — eval gate 1.4 decides;
   even if it loses, graph leg + related_code stand alone.

## Verification commands

`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
`mix test`, `mix sobelow` (touched web surface), EXPLAIN ANALYZE checks on 5433.
