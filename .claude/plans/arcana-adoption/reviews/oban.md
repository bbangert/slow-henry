# Oban Worker Review: arcana-adoption graph extraction

## Summary

The graph write path (`Graph.upsert_from_staged/3`) runs inside `UpsertChunks`'
single Postgres transaction, which is the right call for retry-atomicity: a
crash mid-Multi rolls back chunks + graph + staging cleanup together, so a
retry re-derives everything cleanly from `ON CONFLICT` upserts and full
delete-then-reinsert of mentions/edges. That part is sound. The two real risks
are (1) cross-job lock contention/deadlock on the `entities` unique index when
concurrent `:upsert` jobs (concurrency 5) touch overlapping `qualified_name`
rows, and (2) a genuine TOCTOU race in `force_full_resync_git_sources` where
an in-flight cron `RepoSync` can silently absorb/undo the watermark clear.
GraphGc and job-args discipline are clean.

## Iron Law Violations

None of the 7 iron laws are directly violated. Args stay ID-only (`pending_chunk_ids`, `source_id`) — graph jsonb payloads travel via the `pending_chunks.graph` staging column, never through job args. `unique` constraints are present on all three touched/new workers.

## Issues Found

### Critical (Must Fix Before Deploy)

- [ ] **BLOCKER** — `lib/retrieval_node/graph.ex:611-624` (`write_edges`) and `:417-425` (`upsert_definitions`), concurrent-jobs deadlock. Two `UpsertChunks` jobs (different files of the same source, both legitimately concurrent under `:upsert` concurrency=5) can each `insert_all` a batch of `Entity`/`EntityEdge` rows with `on_conflict: {:replace, ...}` against the same unique index (`[:source_id, :language, :qualified_name]` / `[:source_entity_id, :target_entity_id, :kind]`). Postgres's classic multi-row-upsert deadlock: if batch A contains conflicting keys {X, Y} and batch B contains the same keys in order {Y, X}, each transaction acquires a row lock on its first key and then blocks waiting for the other's lock → deadlock, one transaction aborted by Postgres and retried by Oban. This requires the same `qualified_name` (e.g. a re-exported/shared symbol name) to appear as a definition or edge-endpoint across two files ingested at the same moment — plausible in real corpora (shared module names, common function names like `init`/`start`), not just theoretical. **Fix**: sort each `insert_all` batch's entries by the conflict-target tuple before writing (`Enum.sort_by(entries, &{&1.source_id, &1.language, &1.qualified_name})` / analogous for edges) so all concurrent transactions acquire locks in the same order — the standard fix for this exact Postgres pattern. Cheap (in-memory sort), doesn't change semantics.
- [ ] **BLOCKER** — `lib/retrieval_node/ingest.ex:91-103` (`force_full_resync_git_sources`) races with in-flight `RepoSync` jobs. `RepoSync.perform/1` (`lib/retrieval_node/ingest/workers/repo_sync.ex:56-93`) reads `last_sha` from `sync_state.cursor` at the *start* of `perform`, does its diff/sync work, then writes the new cursor via `advance_watermark` only at the *end* (line 89). If a cron-triggered `RepoSync` for a source is already `executing` (having already read the pre-clear cursor) when `clear_sync_cursor!/1` fires, two things go wrong: (a) `RepoSync`'s `unique` constraint (`keys: [:source_id]`, states incl. `executing`) means `Oban.insert(RepoSync.new(...))` from the backfill task *dedupes onto that already-running job* instead of creating a fresh one — no new full-resync job actually gets enqueued for that source; (b) when the in-flight job finishes, it calls `advance_watermark(sync_state, new_sha)` using the *stale* `sync_state` struct it loaded before the clear, silently re-establishing a "synced to HEAD" cursor and erasing the clear — with `force_full_resync_git_sources` having already reported that source as successfully enqueued. Net effect: for any source with a cron sync in flight at the moment `mix rn.graph.backfill` runs, the full re-sync silently no-ops with no error surfaced, and status/count reporting shows it as done. **Fix**: either (a) have `RepoSync.perform/1` re-fetch `sync_state` immediately before `advance_watermark` (read-modify-write inside the same transaction as the cursor update, or a `WHERE cursor = <the one we read>` optimistic check) so a concurrent clear is respected, or (b) have `force_full_resync_git_sources` check for an executing/scheduled `RepoSync` job for that source first and skip/wait rather than assuming its own `Oban.insert` guarantees a fresh run.

### Warnings

- [ ] **WARNING** — `lib/retrieval_node/graph.ex:70` / `:513-522` `delete_stale_mentions` + `write_edges`'s `delete_all` — verify (not fully confirmed from this file alone) that the extractor's `references[].from` field is always scoped to the *same file* being processed, never another file of the same source. If it can point at an entity defined/referenced elsewhere, two concurrent jobs could both `delete_all` + reinsert edges for the same `source_entity_id`, causing a lost-update race (not double-counting, since weight is fully recomputed from each job's own aggregation — but one job's edges can be clobbered by the other's narrower view). If `from` is guaranteed file-local (per the moduledoc's "one `ChunkFiles` job's worth of chunks" assumption), this is a non-issue — please confirm in `graph/extractor.ex` rather than take this as certain.
- [ ] **WARNING** — `lib/retrieval_node/ingest/workers/graph_gc.ex` — no `timeout/1` callback. `Graph.gc_orphaned_entities/1` loops in 10k batches with no upper bound on iterations; on a multi-million-row orphan backlog (plausible right after the `rn.graph.backfill` re-embed, or after a large repo deletion) a single job could run for a long time occupying one of only 5 `:upsert` queue slots, competing with latency-sensitive `UpsertChunks` jobs. The 4:30am off-peak cron slot mitigates this in the common case but doesn't bound worst-case duration. Consider a `timeout/1` (e.g. 30-60 min) that lets the job finish gracefully via `{:snooze, _}`-and-resume, or split into a chunked/looping Oban job instead of one long-running perform.
- [ ] **WARNING** — `lib/retrieval_node/ingest/workers/upsert_chunks.ex:60-73` — transaction duration/size. Graph writes are now inline in the same transaction as the chunk `insert_all`, so a pathological file (already flagged in this module's own comments as capable of producing tens of thousands of chunks) now also drives proportionally large entity/mention/edge batches inside that one transaction, holding row locks on `entities`/`entity_edges`/`entity_mentions` for the whole duration. Combined with the BLOCKER above, a slow pathological-file transaction increases the *window* during which concurrent jobs can collide on the same unique indexes. No explicit statement/transaction timeout is set here (relies on Postgres/Ecto defaults) — worth confirming the default is acceptable given `:upsert` concurrency 5 and `max_attempts: 5` (a repeatedly-timing-out pathological file will retry 5 times, then land in `discarded`, silently dropping that file's graph data with nothing surfacing it beyond the `discarded` job).

### Suggestions

- [ ] `lib/retrieval_node/graph.ex:453-454` / `:608-609` (`ref_entity_kind/1`, `edge_kind/1`) — these raise `FunctionClauseError` on an unrecognized `"kind"` string from the extractor's jsonb, unlike the sibling `to_enum`/`kind_atom` helpers which raise a descriptive `ArgumentError`. A malformed/future extractor kind value would produce a less diagnosable crash inside the Multi (still safely rolled back, just a worse error message / harder to `{:cancel, _}` a permanently-bad chunk vs retry it 5 times for nothing).
- [ ] `lib/retrieval_node/ingest/workers/graph_gc.ex` `unique` block has no `keys:` — fine given zero args, but worth a one-line comment noting this is intentional (dedup on worker+queue alone) so a future reader doesn't assume it's an oversight.

## Queue Configuration Review

- `:upsert` queue: concurrency 5, unchanged — now hosts `UpsertChunks` *and* `GraphGc` (deliberate, per prompt). Reasonable given GraphGc is a single daily cron job, but see the timeout warning above.
- Cron entry `{"30 4 * * *", RetrievalNode.Ingest.Workers.GraphGc}` — sane cron syntax, off-peak placement is good.
- `Oban.Plugins.Lifeline rescue_after: 20m` — does NOT function as a job timeout; it only rescues jobs whose owning process/node died (stuck in `executing` with no live process). A long-but-alive `GraphGc` run is not rescued or interrupted by this — reinforces the timeout/1 suggestion above rather than substituting for it.
- Pool sizing / other queues unchanged, not reviewed further (out of scope per prompt).

## Idempotency Assessment

- `UpsertChunks` retries: safe. Entire Multi (chunk insert, graph upsert, staging cleanup) is one Postgres transaction — any step failing rolls back all three, so a retry redoes the full unit of work from scratch against unchanged staging rows. `ON CONFLICT` upserts on chunks/entities/edges and delete-then-reinsert on mentions/edges make repeated full-batch execution convergent, not additive — no double-counted edge weights or duplicate mentions from *retries of the same job*.
- Cross-job concurrency (not retries) is the actual risk — see BLOCKER above. This is a lock-ordering/deadlock hazard, not a correctness/double-write hazard: Postgres will abort one of the two conflicting transactions rather than silently corrupt data, so the failure mode is "job retried again" (safe) rather than duplicated state, but it's an avoidable source of noisy retries at scale that gets worse as more repos/files share qualified names.
- `force_full_resync_git_sources`: the TOCTOU race above is the one place this review found where the *idempotent-by-design* pipeline can silently produce an incorrect end state (skipped resync reported as successful) rather than merely retrying safely.
