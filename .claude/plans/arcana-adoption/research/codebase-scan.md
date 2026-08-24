# retrieval_node Codebase Scan — Arcana RAG Library Adoption Fit

Date: 2026-08-18
Scope: assess how much of retrieval_node's hand-rolled RAG stack could plausibly
be replaced/augmented by Arcana (embeddable Elixir RAG lib on Ecto/pgvector/Bumblebee).

## 1. Chunk schema shape

`lib/retrieval_node/retrieval/chunk.ex:15-41` — single unified `chunks` table
(one table for ALL source kinds, deliberately, per the moduledoc at
`chunk.ex:3-7`, so RRF can rank across sources in one scan):

- `source_type` — `Ecto.Enum` of `:git_repo | :jira_project | :drive_folder`
  (`chunk.ex:16`)
- `repo` (string, btree-indexed), `lang` (string, btree-indexed) — hot-path
  filter columns (`chunk.ex:17-18`, migration indexes at
  `priv/repo/migrations/20260714120003_create_chunks.exs:38-41`)
- `chunk_key` (string) + `content_hash` (string) — stable dedup identity,
  unique on `(source_id, chunk_key)` (`create_chunks.exs:37`)
- `content` (text), `context_breadcrumb` (text, e.g. "Class > method") —
  `chunk.ex:21-22`
- `metadata` (jsonb, default `%{}`) — source-varying back-links live here
  (`chunk.ex:23`, moduledoc `chunk.ex:7`)
- `embedding` — `Pgvector.Ecto.Vector`, **384 dims** fixed at the DB level
  (`create_chunks.exs:16`: `add :embedding, :vector, size: 384`)
- `parse_status` enum (`:ok | :heuristic_fallback | :crashed_fallback`,
  `chunk.ex:26-28`) and `secrets_status` enum (`:clean | :redacted`,
  `chunk.ex:30`) — pipeline provenance, not generic RAG concepts
- `tsv` — DB-generated STORED tsvector column (`writable: :never,
  load_in_query: false`, `chunk.ex:36`; generated via raw SQL,
  `create_chunks.exs:26-35`, since Ecto has no DSL for `GENERATED ALWAYS AS`)
- `belongs_to :source` (binary_id FK) — `chunk.ex:38`; `sources` table
  (`create_sources.exs`) holds `source_type`, `name`, `identifier`, `policy`,
  `active`, `config` (jsonb)

**Verdict**: deeply custom, not a drop-in shape for a foreign searcher.
Three specific blockers for any external library's searcher/reranker:
1. Fixed 384-dim vector column (Arcana's embedder would need to match
   dimension exactly, or a schema migration is required — no schema-level
   flexibility here).
2. The DB-generated `tsv` column is bespoke SQL (not portable to a schema a
   library expects to manage itself); a library that owns its own
   migrations would conflict with this custom generated-column trick.
3. `content` (never returned from search — see §2) means any external
   reranker expecting to read text straight off search results would need a
   second fetch step, mirroring what this codebase already does deliberately
   (`search.ex:8` "deliberately *not* full content").
A foreign library could plausibly **read** `chunk_id`/`metadata`/`repo`/`lang`
result rows (the shape is generic enough), but writing its own migrations or
assuming its own chunk schema would collide with this one.

## 2. Hybrid search implementation

`lib/retrieval_node/search/hybrid_query.ex` (158 lines) + `search.ex` (58
lines) = **216 lines total** for the entire search layer.

- Fusion: Reciprocal Rank Fusion, `k=60` (`hybrid_query.ex:37`,
  `@rrf_k 60`), fusion SQL at `hybrid_query.ex:91-99`:
  `SUM(1.0 / (k + rank))` over `UNION ALL` of two ranked CTEs.
- Implemented as **raw SQL via `Repo.query!/2`**, not `Ecto.Query` DSL —
  deliberate choice documented at `hybrid_query.ex:6-28`: a CTE shared
  between both legs got materialized by Postgres and starved both the HNSW
  and GIN indexes (confirmed via `pg_stat_user_indexes` showing
  `idx_scan = 0`); filters are now inlined into each leg's own `WHERE`
  instead.
- Two legs: `vector_search` (`embedding <=> $1::vector` ORDER BY, `LIMIT
  200` candidate pool, `hybrid_query.ex:44,66-77`) and `fts_search`
  (`ts_rank(tsv, websearch_to_tsquery(...))`, `hybrid_query.ex:78-90`).
- Indexes: HNSW (`m=16, ef_construction=64`, cosine ops) on `embedding`, GIN
  on `tsv` — both built `CONCURRENTLY` in a non-transactional migration
  (`priv/repo/migrations/20260714120004_create_chunk_search_indexes.exs:14-23`).
- `@candidate_pool` (200), `@max_top_k` (100), `@rrf_k` (60) are all
  hand-tuned constants (`hybrid_query.ex:37-44`).
- `Search.hybrid_search/2` (`search.ex:32-43`) is the only public context
  entry point: embeds query text (or accepts precomputed embedding), calls
  `HybridQuery.search/1`, maps rows to `%{chunk:, score:}` hits.

**Verdict**: this is a small (216 LOC), extremely tuned piece of code with a
specific, hard-won correctness property (filter-inside-CTE to preserve index
usage) that took live `EXPLAIN ANALYZE`/`pg_stat_user_indexes` investigation
to discover. A generic library's fusion query would need to independently
rediscover or already encode this same constraint — a real risk if adopting
a library's off-the-shelf hybrid query naively (could silently regress to
seq scans at data scale). Low LOC, but high tacit-knowledge density; not an
obvious maintenance burden by line count, but is exactly the kind of code a
library replacement could get subtly wrong.

## 3. Embedding pipeline

- Model: `nomic-embed-text-v1.5`, config-driven repo string
  (`serving.ex:143`, `model_repo/0` reads `Application.get_env`).
- Served via `Nx.Serving` (Bumblebee `Text.TextEmbedding.text_embedding/3`),
  `serving.ex:56-70`: `output_attribute: :hidden_state`, `output_pool:
  :mean_pooling`, `embedding_processor: :l2_norm`, compiled with EXLA,
  `compile: [batch_size:, sequence_length:]` (from config).
- Single named serving (`RetrievalNode.Embedding.ServingProcess`) handles
  both interactive query embeds and bulk `EmbedBatch` indexing jobs —
  documented rationale at `serving.ex:11-21` (avoid duplicating ~1.2GB model
  in RAM; `Nx.Serving` already batches concurrent `batched_run/2` calls
  within `batch_timeout`).
- Native embedding dim: 768 (nomic-embed-text-v1.5 full size). **Matryoshka
  truncation to 384** happens in `nx_serving_impl.ex:85-90` (`matryoshka/1`):
  slice first 384 dims, L2-renormalize, convert to flat float list.
  Documented rationale: "halves storage/compute versus native 768 at <2%
  retrieval-quality cost (validated in Phase 9)" (`nx_serving_impl.ex:19-21`).
- Defensive guards: raises if the tensor isn't rank-1 (pooling
  misconfigured, `nx_serving_impl.ex:73-77`) or has fewer than 384 dims
  (`nx_serving_impl.ex:79-83`); epsilon floor on L2 norm to avoid NaN
  poisoning pgvector (`nx_serving_impl.ex:96,103-104`).
- Warmup: `Serving.warmup/0` (`serving.ex:86-114`) runs a real dummy
  inference through `NxServingImpl.embed/1` at boot (via a `rest_for_one`
  Supervisor + Warmer GenServer, `serving.ex:33-43`), flips a
  `:persistent_term` readiness flag consumed by `/healthz`.
- Pluggable behaviour: `RetrievalNode.Embedding` behaviour with swappable
  impls — `NxServingImpl` (108 lines, prod default), `LlamaCppSidecarImpl`
  (40 lines, alternate/external sidecar), config keys `:embedding_impl` set
  per-env (`config/config.exs:26` prod default `NxServingImpl`,
  `config/test.exs:43` test default `StubImpl`).
- Total embedding subsystem: `serving.ex` (147) + `nx_serving_impl.ex` (108)
  + `supervisor.ex` (37) + `warmer.ex` (33) + `llama_cpp_sidecar_impl.ex`
  (40) = **365 lines**.

**Verdict**: this is the subsystem with the most genuinely hard-won,
non-generic tuning (Matryoshka truncation validated empirically in "Phase
9", specific OTP wiring for warmup/readiness). A library's embedding wrapper
would need to support Matryoshka truncation to 384 specifically to be a
drop-in, or this app would need to change its stored vector dimension
end-to-end (schema, HNSW index, and every downstream consumer).

## 4. Chunking — code-awareness

`lib/retrieval_node/chunking/tree_sitter_impl.ex` (219 lines) is genuinely
AST-aware, not naive text splitting:

- Backed by `tree_sitter_language_pack` NIF (`tree_sitter_impl.ex:23`,
  `alias TreeSitterLanguagePack, as: TS`).
- 7 mainstream languages today: `python javascript typescript go rust ruby
  java` (`tree_sitter_impl.ex:34`).
- Per-language **chunk-boundary node kinds** map (`@chunk_kinds`,
  `tree_sitter_impl.ex:40-51`) — e.g. Python:
  `function_definition class_definition`; Go:
  `function_declaration method_declaration type_declaration`; Rust:
  `function_item struct_item enum_item trait_item impl_item mod_item`.
- Extraction walks the tree recursively (`extract/4`,
  `tree_sitter_impl.ex:137-143`): a chunkable node with chunkable
  descendants (e.g. a class) yields its *members* instead of itself, with
  the container name folded into a breadcrumb scope
  (`emit_or_recurse/5`, `tree_sitter_impl.ex:158-165`) — so methods become
  chunks scoped `"Class > method"`.
- Per chunk it extracts: `text` (source slice), `breadcrumb` (dotted scope
  path), `start_line`/`end_line`, `kind` (the tree-sitter node kind string,
  e.g. `"function_definition"`), `parse_status`
  (`to_chunk/4`, `tree_sitter_impl.ex:198-210`).
- **Symbol/entity extraction is name-only, not reference-aware**: `node_name/2`
  (`tree_sitter_impl.ex:191-196`) pulls the node's `"name"` field (function
  or class identifier) purely to build the breadcrumb string. There is
  **no call-graph, import-graph, or cross-reference extraction** — no
  "this function calls X", no "this module imports Y". `kind` (the grammar
  node type) and the breadcrumb are the only structured signals persisted;
  everything else is flattened into a `context_breadcrumb` string on the
  `Chunk` row and the raw `metadata` jsonb blob is otherwise unused for
  structure.
- Non-code fallback: `heuristic_impl.ex` (110 lines) for unsupported
  languages/timeouts/crashes; Elixir/HEEx/EEx explicitly not yet parsed by
  tree-sitter (fall through to heuristic today — grammars are prefetched
  ahead of a planned native-AST Elixir path, `grammars.ex:9-15`).
- Crash/hang isolation: `guarded/1` runs the parse in a supervised
  `Task.Supervisor.async_nolink` with a 5s timeout
  (`tree_sitter_impl.ex:80-109`) — defends against the tree-sitter NIF not
  being dirty-scheduled (documented limitation, `tree_sitter_impl.ex:13-15`).

**Verdict**: chunking is per-language-grammar-aware and extracts
function/class *names* into breadcrumbs, but does **not** already build a
call-graph or reference graph — a knowledge-graph feature would need new
extraction logic (walking `call_expression`/`import`/`use` node kinds per
language), which is a nontrivial *addition* to this file, not something
already halfway done. The existing per-language `@chunk_kinds` map and node
traversal machinery is directly reusable scaffolding for that addition,
though (same NIF, same guarded-Task wrapper, same per-language table
pattern).

## 5. Ingest pipeline & insertion points

Pipeline stages (Oban-queue-per-stage), `lib/retrieval_node/ingest/`:

1. **`*Sync` workers** (`workers/repo_sync.ex` 204 lines, `workers/jira_sync.ex`
   94, `workers/drive_sync.ex` 118, orchestrated by `workers/sync_scheduler.ex`
   39) — discover raw content, insert `pending_chunks` rows with `status:
   "raw"` and provenance (`source`, `source_id`, `natural_key`,
   `content_hash`, `metadata`) via `PendingChunk.raw_changeset/2`
   (`retrieval/pending_chunk.ex:73-87`).
2. **`ChunkFiles`** (`workers/chunk_files.ex`, 157 lines) — scrub (secrets)
   → chunk (tree-sitter, heuristic fallback) → write N chunk rows →
   enqueue `EmbedBatch` → reap raw row, all in one `Ecto.Multi` transaction
   (`chunk_files.ex:96-126`).
3. **`EmbedBatch`** (`workers/embed_batch.ex`, 53 lines) — fills
   `embedding` on staged chunk rows.
4. **`UpsertChunks`** (`workers/upsert_chunks.ex`, 127 lines) — idempotent
   `ON CONFLICT (source_id, chunk_key)` batch insert into permanent
   `Retrieval.Chunk`, then deletes consumed `pending_chunks` rows, one
   transaction (`upsert_chunks.ex:53-63`).

**Natural insertion point for a graph-extraction step**: `ChunkFiles`
already has exactly the boundary a graph-extraction step would slot into —
right after `Chunking.chunk/2` returns chunk maps with `kind`/`breadcrumb`
(`chunk_files.ex:65-83`) and before `finalize/4` writes rows
(`chunk_files.ex:96-126`). A graph-extraction pass could be added as a
sibling step there (or a new Oban stage after `ChunkFiles`, mirroring the
existing per-stage-queue pattern), writing into `pending_chunks.metadata`
(jsonb, already a free-form field, `pending_chunk.ex:36`) and ultimately
`Chunk.metadata` at upsert time. No schema changes required to stash
graph-edge data as metadata; a proper graph table would be a new migration
+ new Ingest stage.

**Re-sync / incremental update**: `retrieval/sync_state.ex` — one row per
source (`belongs_to :source`, unique on `source_id`,
`sync_state.ex:19,29`), `cursor` jsonb holds a per-source-type watermark
shape (git `last_sha`, Jira `resolutiondate_watermark`, Drive
`start_page_token` — moduledoc `sync_state.ex:2-6`); `status` enum
(`:idle | :syncing | :error`) and `last_error` track sync health. Dedup/
idempotency downstream is via `content_hash` (raw-file level, in
`pending_chunks`) and `chunk_key` (chunk-level stable identity, sha256 of
`natural_key|index|breadcrumb`, `chunk_files.ex:140-143`) with `ON CONFLICT
... DO UPDATE` at final upsert — so re-syncing an unchanged file is a
no-op replace, and a changed file's chunks get new content but the same
`chunk_key` slot iff the breadcrumb/index is stable.

**Total ingest LOC** (excluding `git_mirror.ex`/`scrubber.ex`, which are
source-fetch/security concerns, not RAG-specific): `pending_chunks.ex` (200)
+ workers (`chunk_files.ex` 157 + `upsert_chunks.ex` 127 + `embed_batch.ex`
53 + `repo_sync.ex` 204 + `jira_sync.ex` 94 + `drive_sync.ex` 118 +
`sync_scheduler.ex` 39) = **992 lines** for the ingest orchestration proper
(plus `git_mirror.ex` 592 and `scrubber.ex` 366 as adjacent concerns, total
ingest directory **1,950 lines**).

## 6. MCP layer

`lib/retrieval_node/mcp/` uses the `Anubis.Server` / `Anubis.Server.Component`
pattern (anubis_mcp library):

- `server.ex` (24 lines) — `use Anubis.Server`, declares 4 tools via
  `component/1` macro calls (`server.ex:17-20`): `SemanticSearch`, `Grep`,
  `GetFile`, `ListRepos`.
- Each tool module: `use Anubis.Server.Component, type: :tool`
  (`semantic_search.ex:7`), a `schema do ... field(...) end` block declaring
  the JSON-schema-like input contract (`semantic_search.ex:15-20`), and an
  `execute/2` callback returning `{:reply, Response.json(...), frame}` or
  `{:reply, Response.error(...), frame}`.
- Tools call only `Search`/`Ingest` contexts, never `Repo` directly
  (documented constraint, `server.ex:6-8`).
- `SemanticSearch` (58 lines) is representative: validates/maps a friendly
  `source` param to the DB enum (`@source_map`, `semantic_search.ex:13,39-45`),
  delegates to `Search.hybrid_search/2`, maps results to a flat result map.

**Verdict**: adding a new tool is low-friction — create a module with `use
Anubis.Server.Component, type: :tool`, a `schema do`, an `execute/2`, and
one `component(...)` line in `server.ex`. `GetFile` (39 lines) and
`ListRepos` (20 lines) show the pattern scales down to near-trivial tools
too. No custom MCP protocol/transport code in this app — it's all
declarative on top of `anubis_mcp`.

## 7. LOC by subsystem (RAG-relevant only, `find | wc -l`)

| Subsystem | Files | LOC |
|---|---|---|
| Chunking | `breadcrumb.ex`, `grammars.ex`, `heuristic_impl.ex`, `tree_sitter_impl.ex` | 430 |
| Embedding | `serving.ex`, `nx_serving_impl.ex`, `supervisor.ex`, `warmer.ex`, `llama_cpp_sidecar_impl.ex` | 365 |
| Search | `hybrid_query.ex`, `search.ex` | 216 |
| Ingest orchestration (staging/workers) | `pending_chunks.ex` + 6 workers | 992 |
| Ingest adjacent (fetch/security) | `git_mirror.ex`, `scrubber.ex`, `drive.ex`, `jira.ex` | 1,211 |
| Retrieval schemas | `chunk.ex`, `source.ex`, `sync_state.ex`, `pending_chunk.ex`, `secret_finding.ex` | 286 |
| MCP | `server.ex` + 4 tools | 237 |

**Biggest maintenance burden candidates**: (1) **Ingest orchestration**
(992 lines) is by far the largest RAG-specific subsystem — six Oban workers
plus staging-table CRUD, all bespoke multi-stage pipeline logic
(scrub→chunk→embed→upsert with per-stage idempotency/uniqueness keys). This
is the subsystem most likely to have a direct Arcana analogue (an
embeddable library's own ingest/indexing pipeline) and thus the biggest
potential LOC reduction if Arcana's pipeline can absorb the
staging/chunk/embed/upsert stages — *but* it is also the most tightly
coupled to this app's specific concerns (Oban queue-per-stage, three
heterogeneous source types, a secrets-scrubbing fail-closed step,
tree-sitter/heuristic fallback chains) that a generic library would not
replicate out of the box. (2) **Chunking** (430 lines) is the next
candidate if Arcana ships its own tree-sitter-based chunker, though this
app's per-language `@chunk_kinds` container/member breadcrumb logic
(`tree_sitter_impl.ex:156-165`) is bespoke enough it may not transfer. (3)
**Search** (216 lines) is small but high-risk to replace naively — the
filter-inside-CTE index-preservation fix (§2) is exactly the kind of tuning
a generic library's default query is unlikely to encode, so adopting a
library's hybrid search wholesale risks silently regressing to sequential
scans at scale unless verified with `EXPLAIN ANALYZE` post-adoption.
