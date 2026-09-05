# Scratchpad: ingest-serialization

Decisions log + dead ends. Plan: `plan.md`. Inventory: `ingest-inventory.md`.

## Decisions

- 2026-09-03: Ben rejected the compensating-machinery direction taken in PR #15
  rounds 7–11 (generation guard → file_versions claim → tombstones → digest key).
  Root cause per *Designing Elixir Systems with OTP*: no boundary owned per-file
  state; multiple concurrent writers. Redesign = one `SourceIngest` owner per
  source (Oban unique per source_id incl. :executing = DB-enforced single writer,
  multi-node safe), `pending_chunks` raw rows as the per-source FIFO mailbox,
  functional core `FileIngest.apply/2` per file, discovery workers append-only.
- 2026-09-03 rev 2 — PREMISE CORRECTED by Ben: single BEAM node, no multi-node
  intent. Owner is now a Registry-keyed `SourceOwner` GenServer under a
  DynamicSupervisor (the book's literal boundary); Oban keeps only cron-driven
  discovery. The Oban-unique-job owner (rev 1) was chosen for a multi-node
  guarantee that is moot here.
- Broadway evaluated and rejected: `partition_by: source_id` would order correctly
  on one node, but it needs a custom Postgres producer + ack/failure handling
  (the same retry logic we write anyway), its batching duplicates Nx.Serving's,
  and its strengths (broker integration, firehose back-pressure) don't apply to a
  cron-fed, embed-bound workload. Revisit only if ingestion becomes push/streaming.
- Deletions become queue entries processed in order by the owner — no tombstone.
- Unchanged-content skip + embedding reuse on force re-derivation fall out of the
  owner seeing the whole file version; this also fixes the 39h-backfill cost.

## Dead ends (from PR #15, do not repeat)

- Non-atomic compare-and-set on `max(ingest_generation)` → race (round 8).
- Row-locked claim table (`file_versions`) → correct but adds a table, an
  irreversible migration, a digest key, and tombstone rows; still a patch on a
  multi-writer design.
- Advisory locks per file: same category (serializing at the wrong layer).
- Two terminal paths (UpsertChunks + ChunkFiles zero-chunk shortcut): every
  guard had to be duplicated; the redesign has exactly one path.

## Gates pending

- (rev 1 gate, now moot) Oban snooze accounting — verified `Basic.snooze_job/3`
  bumps max_attempts; irrelevant to the GenServer owner but kept for the record.
- [ ] 0.1 Nx.Serving cross-caller batching for the embedding serving.
- [ ] 0.2 pending_chunks columns for deletion entries + failure marks (additive
  migration, applied to 5433 BEFORE code).
- [ ] 4.2 graph-only force re-derivation wall time vs the 39h baseline.

### HANDOFF for the fresh /phx:work session (2026-09-03)
- Branch state: `feat/reranking-and-code-graph` @ 8d018f2, PR #15 open and
  merge-ready (14 Copilot rounds, all resolved, CI green). The redesign DELETES
  machinery that PR #15 adds (file_versions, ingest_generation, tombstones).
  Recommend: either merge #15 first and do this on a new branch, or branch
  off #15 (`feat/ingest-serialization`) and stack the PR — Ben's call at start.
- Live dev node: detached (setsid) on :4001 against PG 5433 (memory:
  dev-node-durable-launch). Rules: migrate 5433 BEFORE schema-dependent code
  lands in the worktree; config/*.exs changes need a node restart; hot-reload
  otherwise = touch + hit /healthz. Tests: `PGPORT=5433 mix test`.
- Corpus on 5433 is precious (39h backfill): never drop chunks/graph tables.
- Delegate coding to sonnet subagents (memory); verify with real-NIF
  integration tests for extractor/chunking (`--include integration`).
- First tasks: Phase 0 (Nx.Serving cross-caller batching probe; additive
  pending_chunks columns migration applied to 5433 first).

## Work session 2026-09-03 (/phx:work) — decisions

- Branch: `feat/ingest-serialization` stacked on `feat/reranking-and-code-graph`
  (PR #15 untouched; this PR deletes the machinery #15 added).
- 0.1 GATE PASSED: Nx.Serving batches across callers (4×1 → 1 execute, 8×2 → 1,
  3×6 → 2; ~2.0s per 512-token batch regardless of batch fill). No embed semaphore.
- 0.2 DONE: `20260903120001_prepare_staging_for_source_owner` applied to 5433 dev +
  test before code. Columns: pending_chunks.content_hash nullable; attempts (int,
  default 0), last_error, retry_after, force (bool); index (source_id, id);
  chunks.file_hash (raw-file hash the chunk set was derived from → unchanged skip).
- Watermark DEVIATION from plan 2.3 text: discovery commits the cursor in the SAME
  transaction as the row insert (plain write, no CAS) rather than the owner
  committing it after apply. Same guarantee (rows durable ⇒ cursor durable) with
  fewer moving parts, and it avoids a real defect of the deferred design: a
  poison file stuck at max attempts would pin the cursor forever and re-stage the
  whole diff every 15 min. RepoSync `unique` on source_id keeps one writer.
- Backfill: `rn.graph.backfill` no longer clears cursors. It enqueues RepoSync
  with `"full" => true` (diff from nil, rows `force: true`); unique keys become
  `[:source_id, :full]` so a cron sync can't swallow it. Owner treats `force`
  rows as re-derive; embeddings are ALWAYS reused on `(chunk_key, chunk
  content_hash)` match (deterministic model) — force or not.
- Unindexable content (scrub cancel, too_large, binary) now ALSO reconciles the
  file's old chunks away (empty keep-set): the index reflects the current file
  or nothing. Previously stale chunks lingered.
- GraphGc cron becomes per-source through owners (`SourceOwner.gc/1` per source
  with entities): the owner is the single writer of its source's graph rows, so
  `Graph.gc_orphaned_entities` loses FOR UPDATE SKIP LOCKED + recheck and gains a
  `source_id:` scope.
- Tests: `config :retrieval_node, :source_owner_notify, false` in test.exs so
  discovery-worker tests don't spawn owners that race the sandbox; owner tests
  start owners explicitly (`start_supervised`) and drive `drain/1` synchronously
  under `async: false` (shared sandbox). Resume-on-boot kick gated on
  `:ingest_resume_on_boot` (false in test; admin mix tasks put_env false).

## Work session 2026-09-04 — Phase 3 cutover verified, Phase 4 probes, PR

- Found on resume: drop migration `20260904120001_drop_ingest_machinery`
  already applied to 5433 dev AND test; node restarted 02:47 on the new
  code/config; nothing committed on `feat/ingest-serialization` yet.
- Verification: 356 unit + 62 integration green, format/credo/dialyzer/sobelow
  clean, `--status` shows no legacy queues, rpc probe: `queues == [sync: 3]`,
  `Ingest.SourceSupervisor` up, `Workers.ChunkFiles` not loaded.
- Owner pass log gained `embedded=N reused=M` (FileIngest already computed
  them); that is what proves 4.2's reuse claim on the live corpus.
- 4.2: tunnel 2222 chunks in 41 s, checksum identical; stt-proxy 718 chunks in
  23 s, `embedded=0 reused=718`.
- 4.3 probe used a scratch `file://` source (slow-henry's mirror HEAD tracks
  main). The version-B `RepoSync` enqueue via a throwaway `elixir --sname`
  script produced no job (no output captured; the C enqueue with the same
  script worked) — so it ran A → C, not an overlap. Collapse stays covered by
  unit tests. Scratch source + mirror deleted afterwards.
- Corpus-wide zero-mention entities = 550 before the 04:30 GraphGc sweep
  (pre-existing; the daily cron now reaps per source through owners).
- PROCESS (Ben): every plan phase ends in its own PR and work STOPS until it
  merges. PR #15 closed as superseded; this branch carries #15's commits, so
  its PR targets `main`. Phases 0–3 (+ the 4.2/4.3/4.4 probes) ship together
  because they were never split; 4.1's soak concludes after merge.

## 2026-09-04 — PR #16 closed (16k lines); rebuilt as < 2k-line slices

Ben: "absolutely no PR over 2k LoC, absolutely no continuation until a PR has
been merged." #16 was 16,359 additions because this branch was stacked on #15
(15.2k) and the PR targeted main. This branch (`feat/ingest-serialization`)
stays as the REFERENCE for the finished design; each slice below is rebuilt
from `main` in its own worktree (`git worktree add /workspaces/slow-henry-<n>`
— never in `/workspaces/slow-henry`, the dev node hot-loads that tree), tests
run with `PGPORT=5433 MIX_TEST_PARTITION=<n>` so a fresh test DB is built from
that slice's migrations. Measure `git diff --shortstat main` before opening.

Ordered slices (each merged before the next starts; sizes are additions):

1. `feat/ingest-file-core` — `Ingest.FileIngest` core + additive migration
   `20260903120001` + `reconcile_file_chunks`/`file_identity` + tests. ~1.0k.
   Not wired; main's ChunkFiles/EmbedBatch/UpsertChunks untouched. OPENED.
2. `feat/ingest-source-owner` — SourceRegistry/SourceSupervisor/SourceOwner,
   `Ingest.Supervisor`, discovery append+notify (deletion rows, cursor in the
   same txn), delete the three workers + their queues, drain/mark functions in
   PendingChunks, test toggles; ~1.6k. If over: move the drop migration and
   the admin task to slice 3.
3. `feat/ingest-cleanup` — drop per-stage `pending_chunks` columns, admin
   resync/status task (`full` => true, `--source`), resume-on-boot gate, docs.
4. `feat/reranking` — cross-encoder serving/warmer/supervisor, Search rerank,
   MCP flag, healthz, tests. ~1.1k. Independent of 1–3.
5. `feat/graph-schema` — graph tables migration, Entity/Mention/Edge schemas,
   `Graph.upsert_from_staged` + gc, schema tests. graph_test.exs (1.3k) must be
   split between 5 and 8.
6. `feat/graph-extractor-core` — Extractor behaviour + TreeSitter extractor
   for two languages + tests. ~1.2k.
7. `feat/graph-extractor-langs` — remaining languages + tests. ~1.2k.
8. `feat/graph-ingest-wiring` — `Chunking.chunk_with_graph`, FileIngest staged
   rows + `Graph.upsert_from_staged`, GraphGc worker, force re-derive, tests.
9. `feat/graph-search` — HybridQuery entity leg, `related_code` MCP tool,
   bench/rerank_eval tasks, tests. ~1.5k.

The 3.8k lines of `.claude/plans/arcana-adoption/**` reviews/research from #15
never ride along in a code PR; docs-only PR if Ben wants them kept.

## API Failure — 2026-09-04 05:03

Turn ended due to API error. Check progress.md for last completed task.
Resume with: /phx:work --continue

## Slice-2 requirement (from PR #17 Copilot round 5, 2026-09-04)

- text→binary transition leaves stale chunks: `PendingChunks.insert_raw_all/1`'s
  binary guard drops a NUL / invalid-UTF-8 row BEFORE it reaches
  `FileIngest.apply/2`, so a file that was indexed as text and later becomes
  binary never gets its old chunks reconciled away — they stay searchable.
- `apply/2` already handles it IF given a row (the `:binary_content` branch and
  the `status:"deleted"` clause both reconcile with an empty keep-set). The gap
  is the staging seam.
- Could NOT fix in PR #17 (slice 1): `insert_raw_all/1` is shared with the still
  live ChunkFiles/EmbedBatch/UpsertChunks pipeline, which doesn't understand a
  `status:"deleted"` row — repurposing the guard there would poison the old path.
- SLICE 2 fix: when discovery (RepoSync/DriveSync) detects a file became binary
  (guard would drop it), stage an IDENTITY-ONLY deletion/unindexable marker
  instead of dropping, so the owner reconciles the file's stale chunks. Revisit
  the binary guard once the old pipeline is deleted. Add a test that drives the
  real staging seam (not just a forced `:binary_content` on ordinary text).
- PR #17 thread PRRT_kwDOTXolXc6fYVwR left OPEN as the tracked cross-slice item.

## Slice-3 candidate (from PR #20 Copilot round 3, suppressed comments, 2026-09-04)

- Minor operational-status accuracy: the no-change sync paths don't touch
  `sync_states.last_synced_at`, so `--status` shows `last_synced=never`/stale
  for a source that syncs successfully but hasn't changed:
  - `repo_sync.ex` when `new_sha == last_sha` (returns :ok + notify, no touch)
  - `jira_sync.ex` on the `{:ok, []}` path (no resolved issues)
- Not a correctness bug (partly pre-existing on main); Copilot suppressed it.
- Trade-off: touching last_synced_at on every no-change tick is a small write
  per source per 15-min tick (90 sources). Decide in slice 3, which owns the
  admin/status task (`rn.graph.backfill --status` / `rn.seed --status`).
- Deliberately NOT pulled into PR #20 to keep slice 2 focused and merge-ready.

## Slice-2 follow-up (from PR #20 Copilot round 4, deferred, 2026-09-05)

- Boot resume (SourceOwner.resume_all) starts an owner for EVERY source with
  pending work, no global concurrency bound. On a mass restart with a big
  backlog, each owner fetches up to 50 full-content rows and runs chunking
  independently. Embedding is already bounded (Nx.Serving batches across
  callers, Phase-0 spike); chunking is bounded only by dirty-scheduler count;
  per-owner memory (50 rows of file content × N owners) is unbounded.
- Deferred from PR #20 (Ben's call): rare-event hardening, not a correctness
  bug. Steady state runs few concurrent owners. Fix later with a global
  demand/concurrency limit (e.g. a bounded/staggered resume, or a cap on
  concurrently-draining owners) while keeping per-source serialization.
- PR #20 thread PRRT_kwDOTXolXc6fcSm0 left OPEN as the tracked item.

## Slice-2 follow-up addendum (PR #20 Copilot round 8 suppressed, 2026-09-05)

- The boot resume Task is `restart: :temporary`, so `Ingest.Supervisor`'s
  `:rest_for_one` recovery does NOT re-run `SourceOwner.resume_all/0` if the
  Registry or SourceSupervisor later crashes and takes active owners down.
  Durable rows then wait for their source's next sync tick (<=15m) instead of
  being re-kicked immediately. Not data loss — an optimization gap.
- Bundle with the resume-concurrency-bound follow-up (thread PRRT_...cSm0):
  a long-lived, restartable resume coordinator would fix both — re-kick on
  recovery AND a place to bound concurrent owner starts. Do together in the
  resume-hardening follow-up.
