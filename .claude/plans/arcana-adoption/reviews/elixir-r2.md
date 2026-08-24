# Elixir Second-Pass Review: arcana-adoption post-EXPLAIN delta

Scope: files changed after `arcana-adoption-review.md` (hybrid_query.ex entity
leg restructure, graph.ex guards, tree_sitter.ex cap, repo_sync.ex optimistic
watermark, graph_gc.ex timeout, related_code.ex cap, mix tasks). Prior
BLOCKERs/WARNINGs (B1-B3, W1-W3, W5) verified fixed and still in place —
no PERSISTENT prior issues found in this pass.

## Summary
- **Status**: Approved (no blockers)
- **Issues Found**: 4 (0 critical, 1 warning, 3 suggestions)

## Warnings

1. **`lib/retrieval_node/graph.ex:751-758` (`write_edges/2`) — inline sort
   duplicates `sort_by_conflict_key/2` instead of reusing it.** Not a bug
   (the manual `Enum.sort_by(fn {key, _weight} -> key end)` is correct and
   sorts by the same conflict-target tuple), but it silently diverges from the
   pattern used at all three other `insert_all` call sites
   (`upsert_definitions/3`, `upsert_reference_entities/3`,
   `insert_mentions/5`), each of which calls the named helper. A future editor
   changing `sort_by_conflict_key/2`'s semantics (e.g. adding a stability
   tweak or a Logger call) won't touch this site. Fix: `aggregated |>
   Enum.map(fn {k, w} -> {k, w} end) |> sort_by_conflict_key(fn {k, _} -> k
   end)` or simply call the helper with the same anonymous function used here.

## Suggestions

1. **`lib/retrieval_node/search/hybrid_query.ex:208-210` (`entity_matches`) /
   `graph.ex:357` (`edges_query/4`) — no tie-break in `ORDER BY ... LIMIT`.**
   `ORDER BY sim DESC` / `ORDER BY e.weight DESC` with no secondary key means
   Postgres may return a different subset of tied rows across runs (unstable
   plan choice for equal sort keys), which for `entity_matches` could mean a
   symbol at the pool boundary flaps in/out of the top-500 across otherwise
   identical repeat queries. Cosmetic only (non-determinism at a cutoff
   boundary, not a correctness bug) — add `, id`/`, e.id` as a tie-break if
   reproducible ordering across identical queries is ever required (e.g. for
   a regression-test fixture asserting exact entity_leg contents).

2. **`lib/mix/tasks/rn.graph.backfill.ex` — no `--force`/confirmation gate.**
   Still open from the original review's suggestion list (listed there as
   non-blocking); reconfirming it wasn't added in this delta. `mix
   rn.graph.backfill` with no flags immediately clears every active git
   source's watermark and re-embeds the entire corpus (hours of work, per its
   own moduledoc) — a single accidental invocation (e.g. copy-pasted from
   `--status`) has real cost. Not new, not blocking, just still there.

3. **`lib/retrieval_node/graph.ex` `sanitize_graph/1` / `tree_sitter.ex`
   `add_entity`/`add_reference` — cap values verified consistent
   (`@max_symbol_bytes 256` in both), good. One asymmetry worth a comment:
   the extractor skips (never emits) an oversized symbol, so in the normal
   path `sanitize_graph/1`'s filter is pure defense-in-depth and should
   almost never fire — but its `Logger.warning` on `dropped > 0` will now
   fire routinely if *any* future producer (the LLM extractor mentioned
   elsewhere in this codebase) doesn't share the same cap. No fix needed now,
   just flagging that a warning-per-file at scale could get noisy if that
   producer ships without matching the constant — consider exporting
   `@max_symbol_bytes` from one shared module (e.g.
   `Graph.Extractor`) both `TreeSitter` and `Graph` reference, rather than
   two independently-declared literals that must be kept in sync by
   convention/comment alone.

## Verified correct (no finding, checked because flagged as risk areas)

- `significant_terms/1` empty-after-stopwords path: `graph? = graph_requested?
  and terms != []` correctly skips the entity leg entirely; the three-leg SQL
  is never sent with an empty `$9` array.
- `byte_size/1` on `qualified_name`/`name`/`entity` params is unicode-safe as
  a cost proxy (all three cap sites use bytes, not `String.length/1`,
  consistent with the stated "cost scales with input length" rationale).
- `sort_by_conflict_key/2`'s stability claim holds — `Enum.sort_by/2`'s
  default comparator uses a stable merge sort, so pre-chunk ordering survives
  `Enum.chunk_every/2` batch boundaries as documented.
- `RepoSync.advance_watermark/2`'s optimistic `WHERE cursor = ^stale_cursor`
  correctly no-ops (0 rows, warns, doesn't advance) on a concurrent clear —
  matches the moduledoc; `sync_state.cursor` is never `nil` from
  `get_or_create_sync_state/1` (defaults to `%{}`), so the `|| %{}` guards are
  belt-and-suspenders, not load-bearing, but harmless.
- `GraphGc.timeout/1` signature (`timeout(job) :: pos_integer()`) matches
  `Oban.Worker`'s actual callback contract (verified against
  `deps/oban/lib/oban/worker.ex`).
- `RelatedCode.validate_entity_length/1` and `HybridQuery`'s `@max_term_length`
  both gate on byte length before any DB round-trip — correctly ordered before
  the expensive path in both call sites.

No new BLOCKERs. No PERSISTENT reappearance of the three original blockers or
warnings W1/W2/W3/W5.
