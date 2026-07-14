# Review — Retrieval Node, Phases 0–2 (foundation slice)

**Verdict: PASS WITH WARNINGS** · 0 blockers · 0 UNMET requirements
Reviewed: 17 authored files (scaffold/config, 7 migrations, 4 schemas, RRF query + Search API, 1 test).
Agents: elixir-reviewer, security-analyzer, ecto-schema-designer, testing-reviewer, requirements-verifier.

## Requirements Coverage (vs plan.md Phases 0–2 + reconciliation)
12 MET · 2 PARTIAL · 0 UNMET · 2 UNCLEAR
- All canonical reconciliation decisions verified in code: namespaces, `chunk_key`
  ON CONFLICT target, `vector(384)` in BOTH `chunks` and `pending_chunks`, staging
  table adopted, all 7 migrations, 4 schemas, RRF impl. Compile/format/test re-run green.
- PARTIAL (pgvector `~> 0.3` vs locked 0.4.0): **NON-ISSUE** — `~> 0.3` = `>= 0.3.0, < 1.0.0`;
  0.4.0 is permitted and `mix deps.get` resolved it. Verifier mis-stated the `~>` rule.
- UNCLEAR (extension ≥0.5.0): true — no code guard; verified manually (0.8.5). See W3.

## ✅ Fixes applied (post-review)
All 4 actionable findings addressed and verified (6 tests pass, credo/format clean):
1. Filter-isolation test strengthened — added a pool-starvation case (`:rrf_candidate_pool`
   made configurable, set to 5 in test) with 6 higher-ranked out-of-scope decoys; now genuinely
   fails if filters move post-fusion. 2. pgvector `extversion >= 0.5.0` guard added to
   `EnableExtensions` (raises on too-old; runs every test DB create). 3. `top_k` clamped to
   [1, 100] in `HybridQuery`. 4. Three doc comments corrected (`ts_vector`, `chunk`, `secret_finding`).

## Findings worth acting on now (ALL FIXED — see above)

- **[testing · high] Filter-isolation test doesn't prove its property.** With 2 chunks
  and `top_k: 20`, no truncation occurs, so a regression moving the filter *after* fusion
  would still pass. Needs enough out-of-scope higher-ranked decoys (or `top_k: 1`) to force
  an in-scope chunk out of a pre-filter window. Code is correct; the *test* is weak — and this
  is the load-bearing property Phase 2 claims to verify. `hybrid_query_test.exs:74`.
- **[elixir · warn] Stale moduledoc** in `ts_vector.ex` — still cites `load_only: true` as the
  reason `dump/1` is a no-op; actual field opts are `writable: :never, load_in_query: false`.
- **[requirements/security · warn] No pgvector-extension version guard.** Add a runtime/migration
  assertion that `extversion >= 0.5.0` so HNSW support is code-backed, not just manually checked.
- **[security S4 · low] `top_k` unbounded** — bound param, not injectable, but an unbounded LIMIT
  once MCP exposes it. Cheap to clamp in `HybridQuery.search/1`.

- **[ecto · warn] Doc/code mismatches (2):** `chunk.ex` moduledoc says hot filters are
  `source_type/repo/lang` but the query filters `source_id` (both are indexed) — fix wording.
  `secret_finding.ex` moduledoc says "permanent audit record" yet `source_id` FK is
  `on_delete: :delete_all` (matches design spec — "permanent" means across *chunk* re-ingestion,
  not source deletion); clarify the wording.

## Phase 9 watch items (performance — need EXPLAIN ANALYZE at scale, NOT fixable now)
- **[ecto] HNSW + filter interaction:** joining `candidates` before `ORDER BY <=> LIMIT 200`
  is correct for filter semantics but may defeat HNSW's native top-N traversal, forcing a
  full filtered-set sort. Evaluate `hnsw.iterative_scan` during the Phase 9 benchmark (query p99).
- **[ecto] No composite index** on the `(source_id, repo, lang)` hot-filter combo — single-column
  btrees force `BitmapAnd`. Add only if the Phase 9 benchmark shows it matters.

## Deferred (future-phase — noted, not fixed now)
- [elixir] `source_id` cast straight from attrs in changesets — tighten when `Ingest` lands (Phase 6).
- [elixir] `Repo.query!` has no tagged-error path — MCP error contract is Phase 7.
- [security S1] `secret_findings.span` must store offsets only (Phase 5 writer).
- [security S2] `sources.config` jsonb will hold live credentials — add redaction before ingest creds (Phase 6).
- [security S3] `pending_chunks.raw_content` transiently holds pre-scrub secrets — reap abandoned rows (Phase 6).
- [testing] fixtures bypass `upsert_changeset`; add nil-embedding (FTS-only) + empty-result + top_k tests.
- [elixir] `Embedding` docstrings hardcode "384" — source from `dimensions/0` in Phase 3.

## Clean
SQL injection (only compile-time integer interpolation; all user values bound), XSS, atom
exhaustion, path traversal, secret storage (`match_hash` only), content-free hot path,
migration reversibility, index coverage, RRF fusion math.
