# Plan: Serialize ingest per source — one owner process, no compensating machinery

**Slug:** ingest-serialization
**Date:** 2026-09-03 (rev 2: GenServer owner, single-node premise)
**Origin:** Ben's design review of PR #15 (feat/reranking-and-code-graph): the
generation/claim/tombstone/reconcile-guard machinery is symptomatic — the ingest
pipeline mutates per-file state from multiple concurrent writers with no owner.
Apply *Designing Elixir Systems with OTP*: a boundary process owns the state and
serializes access; its mailbox is the queue. **Deployment premise: one BEAM node**
(confirmed by Ben) — multi-node coordination is explicitly out of scope.
Inventory of the current pipeline: `ingest-inventory.md` (this directory).

## Goal

Make "the indexed representation of file F in source S" have exactly one writer
at a time, by construction, so the whole class of ordering/race bugs disappears
— then delete every mechanism that only existed to survive that class.

## Design

### Layers (Do Fun Things with Big Loud Worker-Bees)

- **Data:** raw file version (a `pending_chunks` row), chunk maps, graph payload.
- **Functions:** `Ingest.FileIngest.apply/2` — the whole per-file transform, no
  process concerns: scrub → chunk + extract (one parse) → embed → one write
  transaction (upsert chunks, reconcile the file's chunk set, graph rows, delete
  the raw row). Deletion entries and zero-chunk files are the same function with
  an empty keep-set.
- **Boundary:** `Ingest.SourceOwner` — a GenServer per source, registered by
  `source_id` in `Ingest.SourceRegistry`, started on demand under
  `Ingest.SourceSupervisor` (DynamicSupervisor). It is the ONLY process that
  writes `chunks`/graph rows for its source. Its mailbox serializes; ordering per
  source is a property of the process, not of any DB trick.
- **Lifecycle:** `SourceSupervisor` restarts a crashed owner; the owner re-reads
  its durable queue (the table) on start, so nothing is lost and nothing is
  duplicated (writes are idempotent per `chunk_key`). Owners stop themselves
  after an idle period (`@idle_ms`, e.g. 60s) so 90 sources don't keep 90
  processes alive between syncs.
- **Workers:** discovery stays on Oban (cron-driven `RepoSync`/`DriveSync`/
  `JiraSync`), which is what Oban is good at. Owners run concurrently across
  sources; embedding concurrency is bounded by the `Nx.Serving` (batches across
  callers) — no separate embed queue.

### Mailbox: the per-source FIFO of file versions

`pending_chunks` raw rows ARE the mailbox: bigserial `id` = arrival order =
version order. Discovery workers only *append*: content rows, and explicit
**deletion entries** (`status: "deleted"`, no content) for removed files. Then
they `SourceOwner.notify(source_id)` (starts the owner if needed; a no-op cast
if it is already draining). Discovery never touches `chunks`.

### Owner loop

    notify → (start if absent) → drain:
      rows = oldest N raw rows for this source, id order
      collapse: keep only the newest row per file identity, drop the rest
      for each row: FileIngest.apply(row, force?)   # skip if content_hash unchanged
        {:ok, _} | {:skipped, :unchanged} → row deleted by apply
        {:error, reason} → mark row (attempts+1, last_error, retry_after), continue
      watermark: when the rows of a discovery batch are all applied, commit that
        batch's cursor to sync_states (plain write — single writer, no CAS)
      reap zero-mention entities for this source
      more rows? → loop; else → idle timer → stop

`force: true` (backfill) re-chunks/re-extracts and reuses existing embeddings
when `(chunk_key, content_hash)` match — the graph-only re-derivation path.

### Deleted (the compensating machinery)

`file_versions` table + `identity_hash` + `claim_file_version/4`,
`next_ingest_generation/1`, `tombstone_file/4`, `identity_hash/1`;
`chunks.ingest_generation`, `pending_chunks.ingest_generation`; `chunked_empty`
status and `raw_pending_chunk_id` plumbing; stale-generation skip logic;
optimistic `advance_watermark` CAS; `reconcile_file_chunks` *guards*; the
`ChunkFiles`/`EmbedBatch`/`UpsertChunks` workers and the `chunk`/`embed`/
`upsert` queues; `GraphGc`'s lock-and-recheck (owners reap their own source;
the daily cron remains a simple corpus-wide sweep). `rn.graph.backfill`
re-points at owners (`force: true`, `--source` kept).

### Kept unchanged

Scrubber, Chunking (tree-sitter + heuristic), Graph.Extractor.TreeSitter,
Graph.upsert_from_staged/3 (batching, sorting, language-scoped binding, edge
provenance), Embedding/Reranking servings, Search, MCP tools, GitMirror,
Drive/Jira clients, SyncScheduler + Oban cron/Pruner.

### Considered and rejected

- Oban unique-job owner (plan rev 1): correct, but its single-writer guarantee
  was chosen for multi-node — moot on one node — and it makes ownership implicit
  in a `unique` option with snooze/Lifeline interplay. A process owner is the
  book's literal boundary and reads directly from the supervision tree.
- Broadway (`partition_by: source_id`): ordering would be correct, but it needs a
  custom Postgres producer + ack/failure handling (the same retry logic we write
  anyway, inside a framework), its batching duplicates `Nx.Serving`'s, and its
  strengths (broker integration, back-pressure against a firehose) don't apply
  to a cron-fed, embed-bound workload. Revisit only if ingestion becomes
  push/streaming (webhooks over a broker).

## Key facts constraining the design

- Single BEAM node (Ben). `Registry` uniqueness is sufficient ownership.
- Corpus: 90 active git sources, 578k chunks, 77.6k files; ~8.7k discovery jobs
  per day; embedding at 9–19k chunks/hour is the bottleneck.
- `Nx.Serving` batches concurrent `batched_run/2` callers within
  `batch_timeout` (50ms, batch_size 16) — Phase 0 verifies before relying on it.
- Dev-node rules (memory): migrate 5433 BEFORE schema-dependent code lands in
  the worktree; `config/*.exs` changes require a node restart; launch with the
  detached recipe.
- Data on 5433 is precious (39h backfill): cutover must not drop `chunks`,
  `entities`, `entity_mentions`, `entity_edges`, or embeddings.

---

## Phase 0 — Spike (blocking gates)

- [x] 0.1 [otp] Confirm `Nx.Serving` cross-caller batching for the embedding serving
      config: 3 concurrent `Embedding.embed_batch/1` callers on the dev node → observe
      batch composition via `[:nx, :serving, ...]` telemetry or a probe script. If it
      does not batch across callers, add a small embed semaphore *inside* the owner
      (ordering intact) — decision recorded in scratchpad.
- [x] 0.2 [ecto] Confirm `pending_chunks.raw_content` nullability / what a deletion
      entry needs (`status: "deleted"`, identity in `metadata`, no content). If a
      column change is required, write the additive migration NOW and apply it to
      5433 (schema-first rule) before any code lands. — DONE: `raw_content` was already
      nullable; migration `20260903120001_prepare_staging_for_source_owner` (content_hash
      nullable, attempts/last_error/retry_after/force, (source_id,id) index, chunks.file_hash)
      applied to 5433 dev AND test DB before any code.
- [x] Verify: `mix compile --warnings-as-errors`. (no code yet; migration applied clean)

## Phase 1 — Functional core: `Ingest.FileIngest`

- [x] 1.1 [elixir] `RetrievalNode.Ingest.FileIngest.apply(raw_row, opts)` extracted from
      ChunkFiles/EmbedBatch/UpsertChunks: scrub (fail-closed reap on cancel) →
      `Chunking.chunk_with_graph/2` (heuristic fallback policy unchanged) → embed →
      one `Repo.transaction`: upsert chunks (`chunk_key` identity, ON CONFLICT replace)
      → reconcile the file's chunk set (delete rows whose key isn't produced; empty
      keep-set for deletion/zero-chunk) → `Graph.upsert_from_staged/3` → delete the raw
      row. Returns `{:ok, summary} | {:skipped, :unchanged} | {:error, reason}`. Doc:
      single-writer by contract — callers MUST be the owning `SourceOwner`.
- [x] 1.2 [elixir] Unchanged-content skip (same `(source_id, identity)` already at
      `content_hash` → `{:skipped, :unchanged}`) unless `force: true`, which re-chunks/
      re-extracts and reuses existing embeddings on `(chunk_key, content_hash)` match.
- [x] 1.3 [testing] Unit tests with the existing fakes/stubs: happy path, heuristic
      fallback, scrub cancel reaps, whitespace-only, deletion entry, unchanged skip,
      force reuse-embeddings, rollback on graph failure (no partial chunk write).
- [x] Verify: `mix compile --warnings-as-errors && PGPORT=5433 mix test test/retrieval_node/ingest` — 14 FileIngest tests; suite 380 green. Notes: `chunks.file_hash` drives the unchanged skip; embeddings reused on (chunk_key, chunk content_hash) always; unindexable content (scrub cancel/too_large/binary) reconciles old chunks away; core raises on bugs (owner contains crashes).

## Phase 2 — Boundary: `SourceOwner` + `SourceSupervisor` + `SourceRegistry`

- [x] 2.1 [otp] `Ingest.SourceRegistry` (`Registry`, keys: :unique) and
      `Ingest.SourceSupervisor` (`DynamicSupervisor`) added to `Application` children
      before Oban. `Ingest.SourceOwner` GenServer: `start_link(source_id)` via
      `{:via, Registry, ...}`; `notify/1` = `DynamicSupervisor.start_child` (ignore
      `{:error, {:already_started, _}}`) + `GenServer.cast(:drain)`; `handle_continue`
      after init runs the first drain; drain loop per the design (bounded N rows per
      pass, collapse newest-per-file, `FileIngest.apply/2`, failure marks with
      `attempts`/`last_error`/`retry_after` on the raw row — needs 0.2's columns if
      absent — skip rows whose `retry_after` is in the future); after each pass reap
      this source's zero-mention entities; idle timeout → `{:stop, :normal}`.
- [x] 2.2 [otp] Failure semantics: a file that fails `@max_file_attempts` (5) times is
      left marked (logged at :error, surfaced in `--status`) and no longer blocks the
      queue; a crash of the owner (e.g. NIF) restarts it; the in-flight row is
      re-applied idempotently. `Task.Supervisor`-guarded parse already isolates
      tree-sitter; embed calls are `Nx.Serving` calls with their own timeout.
- [x] 2.3 [oban] Discovery workers append-only: `RepoSync`/`DriveSync` compute changes,
      `PendingChunks.insert_raw_all/1` (+ deletion entries), record the batch cursor
      alongside the rows (e.g. `metadata["sync_cursor"]` on the batch's last row or a
      `sync_batches` note), then `SourceOwner.notify(source_id)`. Remove tombstone/
      claim calls and the CAS watermark; the owner commits the cursor when that
      batch's rows are applied. `JiraSync` same shape (no deletion path today).
- [x] 2.4 [testing] Ordering guarantees (ExUnit, DataCase, Oban manual mode):
      two queued versions of one file → only the newest applied; deletion after
      content → deleted; content after deletion → re-indexed; poison file marked and
      skipped, rest drained; owner crash mid-drain → restart re-applies without
      duplicates; concurrent notifies coalesce (one drain); idle stop + restart on
      next notify; watermark advances only after the batch is applied.
- [x] Verify: `mix compile --warnings-as-errors && PGPORT=5433 mix test` — 386 green, credo/dialyzer clean. Notes: `Ingest.Supervisor` (Registry + DynamicSupervisor + gated resume Task) before Oban; `SourceOwner` notify/drain/gc/stop/resume_all; discovery stages rows + cursor in ONE transaction then notifies; `RepoSync` `"full" => true` (unique keys [:source_id, :full]) replaces cursor clearing; GraphGc sweeps per source through owners on :sync; gc lost its lock/recheck. Test toggles live in test_helper.exs until Phase 3 touches config.

## Phase 3 — Cutover (schema-first, node-aware)

- [x] 3.1 [ecto] Additive migration(s) from 0.2 already applied to 5433 (deletion
      entry + failure-mark columns on `pending_chunks`).
- [x] 3.2 [oban] Config: remove the `chunk/embed/upsert` queues ONLY after 5433's
      legacy staging has drained (`--status`); GraphGc cron simplified. **Restart the
      dev node** for the config change (reloader can't apply config).
- [x] 3.3 [elixir] Switch discovery to append+notify; delete ChunkFiles/EmbedBatch/
      UpsertChunks, the machinery API in `Ingest`, `FileVersion` schema,
      `chunked_empty`, `raw_pending_chunk_id`, CAS `advance_watermark`; re-point
      `rn.graph.backfill` (`--source`, strict args, `force: true`) at owners; update
      moduledocs (UpsertChunks' terminal-path prose → SourceOwner/FileIngest).
- [x] 3.4 [ecto] Destructive migration LAST (after the node runs code that no longer
      references them): drop `file_versions`, `chunks.ingest_generation`,
      `pending_chunks.ingest_generation`; reversible `down` recreates them empty.
- [x] Verify: full suite + `mix credo --strict` + `mix dialyzer` + `mix sobelow`;
      `/healthz` green; `--status` shows no legacy queues; supervision tree shows
      `SourceSupervisor` with owners appearing/disappearing around syncs.
      (2026-09-04: 356 + 62 integration green; credo/dialyzer/sobelow/format clean;
      drop migration applied to 5433 dev+test; node restarted 02:47 on the new
      config — `Oban.config().queues == [sync: 3]`, ChunkFiles not loaded,
      `Ingest.SourceSupervisor` up; first cron tick 03:00: 90 RepoSync completed,
      0 errors, `pending_chunks` empty.)

## Phase 4 — Corpus validation on 5433

- [ ] 4.1 [otp] Let cron run 2+ hours: every source's owner drains, no failure marks,
      `pending_chunks` empty between syncs, watermarks advance, owners idle out.
      (IN PROGRESS since the 02:47 restart: 94 RepoSync completed / 0 failed as of
      03:10, `failed_files` 0, pending 0, owners idle out to 0 between ticks.
      Re-check after the PR merges; do not start Phase 5 work before then.)
- [x] 4.2 [otp] Graph-only backfill via `rn.graph.backfill --source <Elixir repo>`
      (force): wall time + confirmation that embeddings were reused. Record.
      (tunnel: 139 files / 2222 chunks / 1425 entities re-derived in 41 s, embedding
      checksum identical before/after. stt-proxy: 83 files / 718 chunks in 23 s,
      owner log `embedded=0 reused=718`. The old path re-embedded everything.)
- [x] 4.3 [ecto] Ordering probe: two rapid successive commits to the slow-henry source,
      two quick syncs → final chunks match the newest content; the orphan query
      (arcana-adoption scratchpad) returns 0; no stale rows.
      (Done on a throwaway `file://` scratch source, not slow-henry — its mirror
      HEAD tracks main. A → C: final chunks = newest content, one `file_hash`,
      3 entities each with 1 mention, cursor = newest sha. Caveat: the version-B
      sync enqueue failed silently so the two syncs ran A then C sequentially;
      overlapping-batch collapse is covered by source_owner_test. Source deleted.)
- [x] 4.4 [elixir] Live MCP smoke: `semantic_search` + `related_code` unchanged.
      (streamable-HTTP handshake on :4001, `semantic_search` repo=tunnel → 20
      results with breadcrumbs, `related_code` module lookup → entities across
      sources, `isError` false on both.)
- [ ] Verify: full suite + orphan query = 0 + zero failure marks since cutover.

## Risks & self-check

1. **Owner crash loops** on a poison file — per-file marks + max attempts keep the
   queue moving; the supervisor's restart intensity bounds the blast radius.
2. **Watermark semantics** — cursor committed only after its batch is applied (2.3);
   a crash before that re-runs discovery from the old cursor: idempotent.
3. **Throughput** — Phase 0.1 verifies cross-owner batching; fallback is an embed
   semaphore inside the owner. Expect ≥ today's concurrency-1 embed queue.
4. **Data safety** — the destructive migration is last and touches only machinery
   columns/table; legacy staging drains before queues are removed.
5. **Memory** — owners are transient (idle stop); 90 sources never hold 90 processes
   at rest.

## Verification commands

`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
`mix dialyzer`, `mix sobelow`, `PGPORT=5433 mix test` (+ `--include integration`),
`mix rn.graph.backfill --status`, orphan/failure-mark SQL probes on 5433,
`:observer`/`Supervisor.which_children(RetrievalNode.Ingest.SourceSupervisor)`.
