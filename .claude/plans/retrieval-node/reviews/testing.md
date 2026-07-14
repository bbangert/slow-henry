# Test Review: test/retrieval_node/search/hybrid_query_test.exs

## Summary
Three focused tests cover RRF top-rank ordering, filter isolation, and the
public API's back-link projection. Structure is sound (async: true, DataCase
sandbox, deterministic axis vectors). The filter-isolation test's core claim —
"would catch a post-fusion filter regression" — does not hold at the current
dataset size; this is the highest-value fix.

## Iron Law Violations
None (no Mox, no Process.sleep, appropriate async use).

## Issues Found

### Critical
- [ ] **Filter-isolation test cannot catch the regression it targets** (lines 74-106).
  The real bug this test's docstring guards against (`hybrid_query.ex` moduledoc
  lines 10-14) is a filter applied *after* `LIMIT $4` — i.e. an out-of-scope
  chunk consuming a rank-1 slot in the pre-filter top-`k` window, starving an
  in-scope chunk that would otherwise have made the cut. With only 2 total
  chunks and default `top_k: 20`, no truncation can ever occur — both rows
  always survive to the final filter regardless of where it's applied, so a
  regression that moves the filter to after `LIMIT` would pass this test
  unnoticed. Fix: seed >20 repo-b chunks that all score above `in_scope`, pass
  `top_k: 1` (or the default with enough decoys), and assert `in_scope.id` is
  still returned. This is the load-bearing property per the module docs — worth
  the extra fixture setup even for a Phase-2 slice.

### Warnings
- [ ] **Fixtures bypass changesets** (`chunk_fixture/2`, `source_fixture/1` use
  `Repo.insert!(struct(...))` directly). This skips `validate_required` and any
  future upsert-changeset logic, so schema/changeset drift (e.g., a newly
  required field) won't surface as a test failure here even though it would in
  production ingestion. Prefer `Chunk.upsert_changeset/2 |> Repo.insert!()`.
- [ ] **No nil-embedding coverage.** `hybrid_query.ex` explicitly excludes
  `embedding IS NULL` chunks from `vector_search` (line 56) but still lets them
  participate via `fts_search` alone. No test verifies a text-only chunk (nil
  embedding) still surfaces with a fusion score from FTS rank only — an easy
  regression to introduce (e.g. an accidental `INNER JOIN` change) with no test
  to catch it.
- [ ] **No empty-result-path test** — `text_query` matching nothing / embedding
  with no candidates should return `[]`, not error.
- [ ] **No `top_k` truncation test** — nothing exercises `top_k:` actually
  limiting the returned count when more matches exist than the limit.
- [ ] Ordering test only inspects the head element; doesn't assert `_miss` is
  present-but-ranked-lower, so a fusion bug that drops `_miss` entirely (vs.
  ranking it 2nd) wouldn't be distinguished. Minor given test 2 covers filter
  drops separately.

### Suggestions
- [ ] If `chunks.embedding` has an ANN index (ivfflat/HNSW) rather than exact
  search, note that approximate recall is probabilistic even at tiny scale
  depending on `ef_search`/`probes` settings — worth confirming the migration
  uses exact search (no index, or brute force) for these tests, or the ordering
  assertions could flake under CI load. Not verified from the test file alone.
- [ ] Consider a `describe "search/1 tie-breaks"` case for two chunks with
  identical fused scores, to document/pin the resulting secondary sort (or
  absence thereof) rather than leaving it implicit.
- [ ] `chunk_fixture/2` uniqueness relies on `System.unique_integer/1` for
  `chunk_key`/`content_hash` — good, no hardcoded-collision risk.
