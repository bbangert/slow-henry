# Oban Worker Review — Round 2 (arcana-adoption)

## Summary

Both prior BLOCKERs were fixed correctly. `sort_by_conflict_key/2` (graph.ex:788)
applied *before* `Enum.chunk_every` in `insert_all_batched/4` genuinely holds
ordering across batch boundaries for all four insert paths (entity defs,
ref-only entities, mentions, edges) — verified by reading `insert_all_batched/4`
(graph.ex:790-799): the caller sorts the *whole* entry list once, then chunking
only slices an already-sorted list, so per-batch order == global sorted order.
`advance_watermark/2`'s optimistic `WHERE cursor = <read-at-start>` is sound:
Postgres `jsonb =` compares the parsed/normalized representation, not text, so
Elixir map key-insertion order through Ecto's param encoding cannot cause a
false mismatch — this was a non-issue, not a latent bug. Found one new
correctness issue (entity-id resolution ignores `language`) and a few
lower-severity items below.

## Prior Findings Re-Verified

- **FIXED** — cross-job `insert_all` deadlock (graph.ex:513-522/611-624 orig).
  `sort_by_conflict_key` confirmed correct, batch-boundary-safe.
- **FIXED** — `force_full_resync_git_sources` TOCTOU (ingest.ex:91-103,
  repo_sync.ex:193-215). Optimistic `cursor`-match update_all is race-safe;
  0-rows path correctly leaves `status` untouched (never diverges from
  `:idle`, since `clear_sync_cursor!/1` doesn't touch `status`) and logs
  rather than silently corrupting the watermark. `sync_state.cursor` is never
  `NULL` in practice (`get_or_create_sync_state`/`clear_sync_cursor!` both
  default to `%{}`), so the `sync_state.cursor || %{}` guards are defensive
  but the NULL case doesn't actually occur — not a bug either way.
- **FIXED** — `GraphGc` timeout. `timeout/1` (graph_gc.ex:37) is 30 min;
  `gc_orphaned_entities/1`'s batches (graph.ex:120-129) are separate
  auto-committed `delete_all` statements, not one transaction, so a
  timeout-kill mid-run genuinely resumes from where it left off on retry —
  matches the doc comment. `max_attempts: 3` × 30 min = 90 min ceiling before
  `discarded`; on a truly enormous one-time post-backfill orphan backlog this
  could discard with orphans still remaining (next run is the 1-hour `unique`
  window's cron tick, not immediate) — WARNING, not a regression.

## New Issues Found

### Warnings

- **WARNING** — `graph.ex:605-610` (`resolve_entity_ids/3`) and its consumers
  `mention_entries`/`accumulate_edge` (graph.ex:663,672,719) key the
  `entity_ids` map by `qualified_name` alone, dropping `language`. The
  `entities` unique index (and `def_keys`/`collect_reference_entities`
  dedup) is `{source_id, language, qualified_name}` — if one `source_id`
  (repo) legitimately contains two languages whose extractors produce the
  same `qualified_name` string (plausible for short dotted paths like
  `"utils.parse"` across a Python and a JS tree in the same monorepo
  source), `Map.new(rows)` in `resolve_entity_ids/3` silently keeps only one
  language's id, and every mention/edge for the *other* language's entity of
  that name gets silently bound to the wrong entity row — a data-integrity
  bug, not a crash or retry-safe failure. Fix: key by `{language,
  qualified_name}` (or `{source_id, language, qualified_name}`) throughout —
  `resolve_entity_ids`'s `select`, `mention_entries`, `accumulate_edge`, and
  `definition_mentions`/`reference_mentions`'s lookups all need the same key
  shape.
- **WARNING** — `graph.ex:452-480` (`sanitize_graph/1`) logs one
  `Logger.warning` **per staged row** with any oversized symbol, inside the
  `UpsertChunks` transaction (`Enum.map(staged_rows, &sanitize_graph/1)` at
  line 60). For a pathological file with thousands of chunks each carrying
  one oversized symbol (e.g. a minified/generated file with many long
  mangled names), this is thousands of synchronous Logger calls while
  holding row locks on `entities`/`entity_edges` — extends the transaction's
  lock-hold window, compounding the existing WARNING (prior review, still
  present) about transaction duration under concurrency. Fix: accumulate a
  single count/sample across the whole batch and log once in
  `upsert_from_staged/3` after the `Enum.map`, not per row.
- **WARNING (UNVERIFIED — plan-dependent)** — `graph.ex:752` `write_edges/2`'s
  `delete_all(... where: e.source_entity_id in ^source_entity_ids)` is not
  explicitly sorted, unlike the immediately-following sorted `insert_all`.
  Reasoned this is *probably* safe: Postgres's `= ANY(array)` optimization
  sorts the array internally and a plain/bitmap index scan on the
  `{source_entity_id, target_entity_id, kind}` btree visits matching rows in
  the same relative order for any two concurrent transactions touching
  overlapping rows (same physical index), so lock-acquisition order should
  match the sorted insert's order and not reintroduce the deadlock pattern.
  This reasoning is plan-dependent (a seq scan under different planner
  stats would use heap order instead — still consistent across transactions
  scanning the same table state, so still not deadlock-prone, but not
  provably identical to the insert's key order). Given the known
  already-documented overwrite gap here (two files of one source sharing a
  `from`-entity), this pairing gets exercised in exactly the corpora most
  likely to hit it. Not blocking, but worth an explicit `Enum.sort` on the
  delete's key extraction (or just accept and add a one-line comment citing
  the `ANY(array)` sort guarantee so a future reader doesn't have to
  re-derive this) rather than leaving it implicit.
- **WARNING** — `graph_gc.ex` `unique` block (`states: [...]`, no `keys:`)
  combined with `max_attempts: 3` — a `GraphGc` job discarded after 3
  timeout-retries (90 min total) leaves the `unique` window's unrelated
  concern aside, but note the discard is silent beyond the `discarded` job
  row: nothing pages/alerts, and the next attempt is the next cron tick
  (daily per prior review's cron entry), so a very large orphan backlog
  could take multiple days to fully drain with no visible signal beyond
  querying `oban_jobs`. Consider surfacing discard via a `on_discarded`
  telemetry handler or widening `max_attempts` given the job is proven
  idempotent/resumable.

### Suggestions

- `lib/mix/tasks/rn.graph.backfill.ex:129` — `Oban.pause_all_queues(local_only:
  true)` is a no-op given `queues: []` was already set in `boot/0` (line
  116) — an Oban instance configured with zero queues never starts queue
  producers to pause. Harmless (defense-in-depth reads fine) but the comment
  frames it as load-bearing; worth a one-line note that it's belt-and-braces
  against `queues: []` rather than doing independent work, so a future
  reader doesn't assume removing `queues: []` alone would be safe.
- Confirmed no cross-node effect from `boot/0`'s `Application.put_env`
  (queues: [], plugins: []): `mix rn.graph.backfill` runs in its own BEAM
  VM/OS process with its own supervised `Oban` instance reading its own
  `Application` env at that instance's startup — it cannot affect the
  already-running dev-server/systemd Oban's Pruner/Lifeline/Cron plugins,
  which read their own node's env at their own boot. No race with
  `ensure_all_started` either — the `put_env` calls happen synchronously
  before it in the same process. This item, raised as a question in the
  prompt, checks out — no action needed.
- Pre-existing discarded `RepoSync` rows (88) and completed-after-retry
  `UpsertChunks` rows (2) are inert history; the new `unique` states list
  (`repo_sync.ex:43`, `upsert_chunks.ex:22`) correctly excludes `:discarded`/
  `:completed`/`:cancelled` (matches Oban defaults), so old discarded jobs
  don't block new inserts for the same key. Nothing in this diff reads or
  reacts to historical job rows, so no mishandling risk there.

## Idempotency Assessment

No change to the prior assessment's conclusion: retries remain safe
(single-transaction Multi, convergent upserts). The new entity-id
language-collision issue is a *correctness* risk (wrong-entity binding), not
a retry-safety risk — re-running the same buggy logic just re-produces the
same wrong binding, it doesn't compound across retries.
