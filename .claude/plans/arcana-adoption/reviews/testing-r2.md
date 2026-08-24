# Test Review R2: arcana-adoption (post-fix pass)

## Summary
Verified the addendum's claimed fixes against actual test code. The
`advance_watermark` race test, `graph_gc` timeout test, `reranking_test`
async isolation, and ci.yml integration wiring all check out as claimed. Two
prior WARNINGs (hops validation, call-weight ordering) were only partially
addressed and PERSIST. The most significant NEW gap: the addendum-2
stopword-filtering fix to `significant_terms/1` — the change that produced
the 1.29s→43ms latency win — has **zero direct test coverage** of the
`@stopwords` set itself.

## Verified As Claimed
- `.github/workflows/ci.yml:121-122` — `mix rn.grammars.prefetch` +
  `--include integration test/retrieval_node/graph/extractor
  test/retrieval_node/chunking` is present and would catch a broken
  extractor; `tree_sitter_test.exs:260` oversized-symbol test lives under
  that path and the `:integration` tag.
- `repo_sync_test.exs:222-264` — genuine race: DB row is mutated via a real
  `Repo.update!` between struct load and `advance_watermark/2` call using the
  stale struct; asserts `"not advancing watermark"` log + cursor stays
  cleared. Normal-path advance test (`:223`) also present. No gaps.
- `reranking_test.exs:2-5` — `async: false` with inline justification;
  grep across all diffed test files for `put_env` confirms every module that
  mutates global `Application` env (`chunking_test.exs`, `graph_test.exs`,
  `graph_gc_test.exs`, `repo_sync_test.exs`) is `async: false`. No
  async+global-mutation violations in the diff.
- `graph_gc_test.exs:76-77` — timeout test asserts only the static
  `timeout/1` return value, not behavior — acceptable given Oban timeout
  behavior isn't practically unit-testable; matches addendum's claim exactly
  (no overclaim).
- `graph_test.exs:137-184` — oversized-entity/reference test pins the actual
  warning log text and confirms surviving rows (`"a"`, `"b"`) plus asserts no
  entity name exceeds 256 bytes. Solid.

## Issues Found

### Critical
- None.

### Warnings
- **`lib/retrieval_node/search/hybrid_query.ex:82-88` (`@stopwords`) /
  `test/retrieval_node/search/hybrid_query_test.exs:314-346`** — the
  `significant_terms/1` describe block never exercises the stopword branch.
  Every existing case either uses non-stopword filler ("check",
  "process_payment", "payment", "term1".."term12") or words dropped purely
  by the `< 3 chars` length rule ("a", "to", "is"). No test asserts that an
  actual multi-char stopword (e.g. `"with"`, `"about"`, `"into"`) is dropped
  despite passing the length filter, and no test asserts the flip side the
  moduledoc explicitly calls out as deliberate — a common-English/common-
  code word like `"get"` or `"all"` surviving because it's NOT in
  `@stopwords`. This is the exact logic that produced the addendum-2 43ms
  perf win and it ships untested. Fix: add cases —
  `significant_terms("with about into payment") == ["payment"]` and
  `significant_terms("get all things") == ["get", "all", "things"]`.
- **`test/retrieval_node/search/hybrid_query_test.exs:422-452`** —
  PERSISTENT from prior review. The `:definition`-vs-`:import` mention-kind
  test still only checks two of three tiers; `:call` (weight 0.6) is never
  placed in a three-way ordering assertion (`definition > call > import`).
  Not touched by the entity_matches restructure, but the restructure did
  change the SQL shape scoring runs through (`entity_matches` → join →
  `MAX(sim * CASE em.kind ...)`), so this gap now also means the new
  MATERIALIZED-CTE scoring path's middle tier is unverified end-to-end.
- **`test/retrieval_node/mcp/tools_test.exs`** (`related_code` describe,
  ~253-420) — PERSISTENT from prior review. Still no test for
  `hops: 0`/`hops: 3` (the `normalize_hops/1` error branch,
  `lib/retrieval_node/mcp/tools/related_code.ex:124-126`) and still no
  `lang` filter test for `related_code` (only `repo` is exercised at
  `:346`). Both were called out in the first-pass review and were not part
  of the addendum's fix list, so they remain open.
- **`lib/retrieval_node/graph.ex:452-480` (`sanitize_graph/1`)** — new gap.
  The function is written to tolerate a graph carrying only one of
  `"entities"`/`"references"` (the `Map.put` comment at :472-473 explicitly
  calls this out as a real case), but no test constructs a staged row with
  only one key present. Also untested: a non-list value under either key
  (e.g. `"entities" => nil` from a malformed staged row) — `Enum.filter`
  over a non-list would raise a `Protocol.UndefinedError`/`FunctionClauseError`
  inside the `UpsertChunks` transaction rather than being dropped with the
  same "junk must never take real chunks down" warning the moduledoc
  promises. Add a case for each.

### Suggestions
- `test/retrieval_node/graph/graph_test.exs` fixture duplication
  (`seed_chunk`/`seed_entity`/etc. across `graph_test.exs`,
  `graph_gc_test.exs`, `hybrid_query_test.exs`, `tools_test.exs`) is still
  unaddressed — carried over as a suggestion, not blocking.
