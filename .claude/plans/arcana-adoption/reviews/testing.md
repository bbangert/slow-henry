# Test Review: arcana-adoption (graph, reranking, MCP tools)

## Summary
The new graph/reranking/MCP test suites are unusually thorough and honest
(deterministic StubImpl assertions, real ExUnit.CaptureLog verification,
filter-isolation pool-starvation tests). The main gaps are (1) the entire
tree-sitter graph-extraction engine — the actual new AST->entity/reference
logic — is covered *only* by `:integration`-tagged tests that CI's default
`mix test` never runs, and (2) a couple of `Search`/`related_code` edge
cases named in the review brief have no direct test.

## Iron Law Violations
None found (async defaults are justified with inline comments, sandbox use
is correct, verify_on_exit! N/A since no Mox here, no mocking across
boundaries — StubImpl/HeuristicImpl are legitimate behaviour-backed fakes).

## Issues Found

### Critical

- **`test/retrieval_node/graph/extractor/tree_sitter_test.exs:7`** — `@moduletag :integration`
  on the *entire* file. This is the only test coverage for
  `RetrievalNode.Graph.Extractor.TreeSitter` (qualified-callee resolution,
  class/method scoping, import aliasing) — genuinely new, non-trivial
  business logic — and it is fully excluded from the default `mix test`
  run (`test/test_helper.exs:4` excludes `:integration`). Per the review
  brief's "CI would never run them" check: this is exactly that case. Fix:
  either (a) add a small non-integration smoke test that exercises
  `GraphExtractor.TreeSitter.extract/3` through a fake/pre-built AST fixture
  (no NIF), or (b) explicitly wire `--include integration` into the CI
  pipeline so this isn't silently skipped, and note that decision in the
  moduledoc/CI config so it's not accidental.

### Warnings

- **`lib/retrieval_node/search.ex:81-99` (`rerank_hits/3`)** — the
  empty-candidate-pool clause (`rerank_hits(_query_text, [], _top_k)`) and
  the "content row missing between HybridQuery read and content fetch"
  drop-path (`Enum.flat_map`/`Map.fetch` miss branch) have no direct test.
  `hybrid_query_test.exs`'s rerank describes only exercise the happy path
  with all chunks present. Add: (1) a `rerank: true` search against a query
  with zero HybridQuery hits (e.g. filtered to a nonexistent repo) asserting
  `[]` back instead of a crash, and (2) a test that deletes/never-inserts a
  chunk's row between candidate selection and content fetch (e.g. call
  `Search.hybrid_search/2` with `:rerank` after `Repo.delete_all(Chunk)` on
  one id, or stub via a race using a chunk id from `HybridQuery.search/1`
  output that's manually removed from `content_by_id`) to prove it's
  dropped, not raised.
- **`lib/retrieval_node/search.ex:63`** (`query_top_k = max(rerank_candidates(), top_k)`)
  — untested for the case `top_k > rerank_candidates()` (e.g. caller asks
  for `top_k: 80` against the default 50-candidate pool). Only
  `hybrid_query_test.exs`'s funnel test uses `top_k: 2`/`top_k: 4`, both
  well under the candidate pool. Add a case asserting the funnel still
  returns `top_k` hits (or fewer, if the corpus can't supply that many)
  when `top_k` exceeds `rerank_candidates()`.
- **`test/retrieval_node/mcp/tools_test.exs`** (`related_code` describe,
  ~line 253-350) — no negative-param tests for `hops` outside `{1,2}` (e.g.
  `hops: 3` or `hops: 0`) even though `RelatedCode.normalize_hops/1`
  (`lib/retrieval_node/mcp/tools/related_code.ex:124-126`) has a dedicated
  error branch for it, and no test for the `lang` filter on `related_code`
  (only `repo` is exercised). Both are simple to add alongside the existing
  "an invalid relation is rejected" test.
- **`test/retrieval_node/search/hybrid_query_test.exs`** entity-leg kind
  weight tests (~line 416-446) compare `:definition` vs `:import` only;
  `:call` (weight 0.6, the middle tier) is never asserted to rank between
  them. Given the review brief explicitly calls out "kind weights" as a
  coverage target, add a three-way ordering assertion
  (`definition > call > import`).
- **`test/retrieval_node/ingest/workers/graph_gc_test.exs:23-25`** — the
  `Logger.configure`/`on_exit` revert pattern is correct and well-commented,
  but relies on `prev = Logger.level()` captured *after* any other test may
  have already mutated it this run; since this file is `async: false` and
  the mutation window is scoped to its own tests, this is fine as written —
  no action needed, flagging only because the brief asked to verify it (it
  checks out).

### Suggestions

- **`test/retrieval_node/graph/graph_test.exs`** — heavy duplication of
  `seed_chunk`/`seed_entity`/`seed_mention`/`seed_edge` helpers, near-
  identically re-defined in `graph_gc_test.exs` and again (with a `repo`
  param) in `hybrid_query_test.exs`/`tools_test.exs`. Consider hoisting a
  shared `RetrievalNode.GraphFixtures` support module (mirroring
  `test/support/fake_chunking_impl.ex`'s pattern) to cut ~80 lines of
  duplicated fixture code across 4 files and reduce drift risk when the
  schema changes.
- **`lib/mix/tasks/rn.graph.backfill.ex`** has no test coverage at all, but
  its real logic (`Ingest.force_full_resync_git_sources/0`,
  `Ingest.backfill_status/0`) is tested in `ingest_test.exs`; only the thin
  CLI wrapper (arg parsing, boot/halt sequencing) is untested, which is
  conventional for a `Mix.Task` — no action required, noted for
  completeness only.
- **`test/retrieval_node/graph/graph_test.exs:502-511`** (`:limit` test) —
  the comment admits the assertion doesn't meaningfully exercise the
  `:limit` option (`length(...) <= 50` is trivially true for 5 seeded rows).
  Worth seeding >50 same-suffix entities once to make the cap assertion
  load-bearing, or drop the claim from the test name.

## Pre-existing (one-liners, not new)
- `test/retrieval_node/reranking/supervisor_test.exs:100` — polling
  `Process.sleep(10)` loop is bounded by a deadline+flunk, not a bare sleep;
  acceptable pattern, not flagging as a violation.
