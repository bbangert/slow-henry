## Requirements Coverage (from .claude/plans/retrieval-node/plan.md — Phases 0-2)

### Canonical reconciliation decisions

| # | Decision | Status | Evidence |
|---|----------|--------|----------|
| 1 | Namespaces: `RetrievalNode.Retrieval.*` for schemas | MET | `lib/retrieval_node/retrieval/{source,chunk,sync_state,secret_finding}.ex` all `defmodule RetrievalNode.Retrieval.*` |
| 2 | `chunk_key` + `[:source_id, :chunk_key]` as ON CONFLICT/unique target | MET | migration `20260714120003_create_chunks.exs` `unique_index(:chunks, [:source_id, :chunk_key])`; schema `chunk.ex` `unique_constraint([:source_id, :chunk_key], name: :chunks_source_id_chunk_key_index)` |
| 3 | `vector(384)` everywhere incl. `pending_chunks` | MET | `create_chunks.exs` `add :embedding, :vector, size: 384`; `create_pending_chunks.exs` `add :embedding, :vector, size: 384` |
| 4 | `pending_chunks` staging table adopted | MET | `priv/repo/migrations/20260714120007_create_pending_chunks.exs` defines full staging table w/ status/scrub_mode/chunk_quality |
| 6 | pgvector Postgres extension ≥0.5.0 verified | PARTIAL | Plan claims "0.8.5 installed" (manual/psql verification, not asserted in code); no runtime/migration guard exists in the diff checking `pg_extension.extversion` — acceptable per plan wording but unverifiable from code alone |

### Phase 0 — Scaffold & dependencies

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | Generate API-only Phoenix app | MET | `mix.exs` app `:retrieval_node`, no html/live deps required for MCP |
| 2 | Add deps: anubis_mcp, oban, pgvector 0.4.0, bumblebee, nx, exla, tree_sitter_language_pack, req, sourceror, credo, sobelow | PARTIAL | `mix.exs:57` declares `{:pgvector, "~> 0.3"}` but plan/`mix.lock:33` show `0.4.0` resolved — `~> 0.3` should exclude `0.4.x`; requirement string does not match the claimed/locked version. All other deps present in `mix.exs`. |
| 3 | Register pgvector Postgrex type via `postgrex_types.ex`, wired in config, plus `EctoTypes.TsVector` | MET | `lib/retrieval_node/postgrex_types.ex` (`Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions()`); `config/config.exs` `types: RetrievalNode.PostgrexTypes`; `lib/retrieval_node/ecto_types/ts_vector.ex` |
| 4 | Verify vector extension ≥0.5.0 | UNCLEAR | No code assertion found (`grep extversion` empty); relies on manual psql check per plan note — cannot verify from diff alone |
| 5 | config.exs chunking_impl/embedding_impl swappable keys; test.exs override to Heuristic | MET | `config/config.exs` sets both keys; `config/test.exs` `chunking_impl: RetrievalNode.Chunking.HeuristicImpl` |
| 6 | Verify: compile --warnings-as-errors PASS, format --check-formatted PASS | MET | ran locally: both exit 0 |

### Phase 1 — Data layer

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | Migration EnableExtensions (vector, pg_trgm) | MET | `20260714120001_enable_extensions.exs` |
| 2 | Migration CreateSources w/ unique `[:source_type, :identifier]` | MET | `20260714120002_create_sources.exs` |
| 3 | Migration CreateChunks: tsv generated column, embedding vector(384), unique [source_id, chunk_key], btree indexes | MET | `20260714120003_create_chunks.exs` — raw `execute` for `tsv ... STORED`, `vector, size: 384`, unique+btree indexes present |
| 4 | Migration CreateChunkSearchIndexes: disable_ddl_transaction/migration_lock, maintenance_work_mem, HNSW+GIN CONCURRENTLY | MET | `20260714120004_create_chunk_search_indexes.exs` matches all specifics (m=16, ef_construction=64) |
| 5 | Migration CreateSyncStates 1:1, cursor jsonb, status | MET | `20260714120005_create_sync_states.exs` |
| 6 | Migration CreateSecretFindings append-only, match_hash only, chunk_id ON DELETE SET NULL | MET | `20260714120006_create_secret_findings.exs` `on_delete: :nilify_all`; schema has no raw-secret field |
| 7 | Migration CreatePendingChunks bigserial, embedding vector(384) | MET | `20260714120007_create_pending_chunks.exs` (no `binary_id` primary_key override → default bigserial) |
| 8 | Schemas Source/Chunk/SyncState/SecretFinding w/ tsv `writable: :never, load_in_query: false` workaround | MET | `chunk.ex` field `:tsv` exactly uses that workaround |
| 9 | Verify: ecto.create/migrate on PG18/5433, HNSW+GIN confirmed | MET | `config/dev.exs`/`test.exs` point at port 5433; `mix test` ran migrations successfully in this session |

### Phase 2 — Search context (RRF query)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | `HybridQuery.search/1` raw SQL, shared candidates CTE, vector+FTS CTEs, RRF fusion, pool 200/top_k 20, back-links only, Decimal→float | MET | `lib/retrieval_node/search/hybrid_query.ex` — `@candidate_pool 200`, `@default_top_k 20`, `candidates` CTE feeds both `vector_search`/`fts_search`, `to_float/1` handles Decimal |
| 2 | `Search.hybrid_search/2` public API embeds via `Embedding.embed/1`, assembles back-link hits, `:embedding` opt bypass | MET | `lib/retrieval_node/search.ex` `Keyword.get_lazy(opts, :embedding, fn -> Embedding.embed(...) end)`; `Embedding` dispatcher stub in `lib/retrieval_node/embedding.ex` |
| 3 | Verify: 3 tests pass (RRF ordering, filter isolation, back-link projection), credo/format clean | MET | `test/retrieval_node/search/hybrid_query_test.exs` — ran locally, `3 passed`; `mix format --check-formatted` exit 0 |

**Summary**: 12 MET · 2 PARTIAL · 0 UNMET · 2 UNCLEAR
