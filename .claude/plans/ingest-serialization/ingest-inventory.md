# Ingest Pipeline Inventory (branch feat/reranking-and-code-graph)

## 1. Modules — lib/retrieval_node/ingest/ (+ workers/)

|Module (LOC)|Purpose|Queue|unique keys/period|timeout|Enqueues|Writes|
|---|---|---|---|---|---|---|
|workers/chunk_files.ex (258)|scrub→chunk raw row→write chunks→enqueue EmbedBatch (or UpsertChunks if 0 chunks)|chunk|1h `[pending_chunk_id]`|45s|EmbedBatch; UpsertChunks(empty)|pending_chunks (insert/update/delete raw); secret_findings|
|workers/drive_sync.ex (147)|Drive Changes API discover job|sync|30m `[source_id]`|default|ChunkFiles|pending_chunks; chunks(tombstone del); sync_states; file_versions|
|workers/embed_batch.ex (64)|embeds staged chunks, enqueues terminal upsert|embed|1h `[pending_chunk_ids]`|default|UpsertChunks|pending_chunks(set_embeddings)|
|workers/graph_gc.ex (60)|cron sweep, reaps zero-mention entities|upsert|1h, no keys (singleton)|30m|none|entities/entity_edges via Graph.gc_orphaned_entities/1|
|workers/jira_sync.ex (94)|Jira resolved-issues discover job|sync|1h `[source_id]`|default|ChunkFiles|pending_chunks; sync_states (no delete path)|
|workers/repo_sync.ex (279)|git diff --raw discover job|sync|15m `[source_id]`|default|ChunkFiles|pending_chunks; chunks(tombstone del); sync_states(CAS); file_versions|
|workers/sync_scheduler.ex (39)|cron fan-out per source kind|sync|none|default|Drive/Jira/RepoSync|none|
|workers/upsert_chunks.ex (358)|ONE terminal stage: claim version, upsert, reconcile stale, persist graph, cleanup staging|upsert|30m `[pending_chunk_ids, raw_pending_chunk_id]`|default|none (terminal)|chunks(upsert); file_versions(claim); pending_chunks(del); entities/mentions/edges via Graph.upsert_from_staged/3|
|drive.ex (129)|Drive REST client, used by DriveSync|—|—|—|—|none|
|git_mirror.ex (592)|git shell-out facade, used by RepoSync + MCP tools|—|—|—|—|none|
|jira.ex (124)|Jira REST client, used by JiraSync|—|—|—|—|none|
|pending_chunks.ex (200)|data access for pending_chunks|—|—|—|—|pending_chunks|
|scrubber.ex (366)|secret detect/redact pre-step for ChunkFiles|—|—|—|—|secret_findings|

max_attempts: 5 for `*Sync`/ChunkFiles/UpsertChunks; 3 for EmbedBatch/GraphGc/SyncScheduler.

## 2. RetrievalNode.Ingest public API (ingest.ex, 469 LOC)

Core catalog (non-machinery): `list_repos/0`, `resolve_git_repo/1`, `git_repo_slugs/0`.

Generation/claim/tombstone/reconcile machinery ONLY: `force_full_resync_git_sources/0`, `force_full_resync_git_sources/1`, `backfill_status/0`, `file_identity/2`, `reconcile_file_chunks/5`, `identity_hash/1`, `claim_file_version/4`, `next_ingest_generation/1`, `tombstone_file/4`.

## 3. Staging

**PendingChunk** (retrieval/pending_chunk.ex): bigserial `id`; bookkeeping `status`(default `"raw"`)/`scrub_mode`/`chunk_quality`/`raw_content`; provenance `source`/`source_id`/`source_type`/`repo`/`lang`/`natural_key`/`content_hash`/`metadata`; chunk-level `chunk_index`/`chunk_content`/`chunk_key`/`context_breadcrumb`/`parse_status`/`secrets_status`/`embedding`/`graph`/`ingest_generation`; timestamps. Status flow: `raw` → `chunked`(write_chunks) or `chunked_empty`(ChunkFiles 0-chunk path) → `embedded`(set_embeddings).

**pending_chunks.ex (200 LOC)** public fns: `insert_raw_all/1`, `insert_raw/1`, `fetch!/1`, `get/1`, `fetch_many!/1`, `write_chunks/3`, `set_embeddings/1`, `by_ids/1`, `delete_by_ids/1`.

## 4. Compensating-machinery migrations (priv/repo/migrations/20260902*.exs)

|File|Adds|
|---|---|
|120001_add_ingest_generation_to_chunks|`chunks.ingest_generation :bigint, null:true` (provenance only)|
|120002_add_ingest_generation_to_pending_chunks|`pending_chunks.ingest_generation :bigint, null:true`|
|130001_create_file_versions|table `file_versions`(id binary_id, source_id FK, identity text, generation bigint, timestamps); unique_index `[source_id,identity]`|
|150001_hash_file_version_identity|adds `identity_hash string(64)`, SQL sha256 backfill, swaps unique index to `[source_id,identity_hash]`; **irreversible** (`down/0` raises)|

## 5. Deletion & watermarks

`RepoSync.delete_one_path/2` and `DriveSync.delete_one_doc/2` both call `Ingest.tombstone_file/4` (claim fresh generation → conditional delete on `chunks` only if `:claimed`), never unconditional delete. Jira has **no removal path**. Watermarks: `RepoSync.advance_watermark/2` (public, `@doc false`) does optimistic `Repo.update_all` matched against in-memory cursor (0-row match ⇒ warn+skip). `DriveSync`/`JiraSync` `advance_watermark/2` (private) do unconditional `SyncState.changeset/2` + `Repo.update!`.

## 6. Oban config (config/config.exs)

Queues: `sync:3, chunk:2, embed:1, upsert:5`. Plugins: `Pruner max_age:14d`, `Lifeline rescue_after:20m`, `Cron`(RepoSync `*/15` git, JiraSync hourly, DriveSync `*/30`, GraphGc `30 4 * * *`). Locked oban version (mix.lock): **2.23.0**.

## 7. Graph write entry point / GraphGc

`RetrievalNode.Graph.upsert_from_staged(repo, staged_rows, chunk_ids_by_key)` — graph.ex:55/58, raises `ArgumentError` if staged rows span >1 `source_id`. GraphGc: cron daily `30 4 * * *`, queue `upsert`, unique 1h no keys (app-wide singleton) — no advisory lock; relies on `Graph.gc_orphaned_entities/1`'s batched idempotent delete loop for safe timeout-retry resume.

## 8. Test coverage

|File|LOC|tests|describes|
|---|---|---|---|
|ingest/git_mirror_test.exs|342|23|5|
|ingest/ingest_test.exs|252|16|5|
|ingest/pending_chunks_test.exs|174|12|0|
|ingest/pipeline_test.exs|184|8|1 (Chunk/Embed/Upsert e2e)|
|ingest/scrubber_test.exs|205|22|6|
|ingest/sources_test.exs|468|16|6 (Jira/Drive clients, Scheduler, JiraSync, DriveSync, uniqueness)|
|ingest/workers/graph_gc_test.exs|79|3|0|
|ingest/workers/order_safety_test.exs|301|5|1 (claim/stale race)|
|ingest/workers/repo_sync_test.exs|420|15|2|
|ingest/workers/upsert_chunks_test.exs|350|7|1|
|graph/graph_test.exs|1291|41|13 (incl. upsert_from_staged/3, gc_orphaned_entities/1)|

**Total: 11 files, 3,566 LOC, ~158 tests.**
