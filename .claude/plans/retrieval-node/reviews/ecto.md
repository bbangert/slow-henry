# Ecto Data Layer + RRF Review — Phase 0-2 Slice

No Ash detected (`grep -E "ash_postgres|use Ash.Resource"` empty). Plain Ecto patterns apply throughout.

## Summary

Overall solid: vector(384) is consistent everywhere (chunks + pending_chunks, no 768 leaks), the
`candidates` CTE correctly gates both ranking CTEs before the window functions run (the documented
correctness property holds), RRF math (`1.0/(k+rank)`, k=60, rank from `row_number()` starting at 1)
is correct, Decimal→float conversion is handled, and the generated `tsv` column / concurrent index
migrations are properly structured and reversible.

## WARNING

1. **`secret_findings.source_id` cascades `:delete_all`, contradicting the "permanent audit record" design intent.**
   The moduledoc states this table is "the permanent record of *what* was found" and `chunk_id` uses
   `:nilify_all` specifically so the audit row survives chunk re-ingestion — but `source_id` is
   `null: false` + `on_delete: :delete_all`, so deleting a *source* silently deletes its entire secret
   audit trail. If audit permanence must survive source removal too, either make `source_id` nullable
   with `:nilify_all`, or use `:restrict` to force explicit archival before a source can be removed.

2. **Filtered-ANN performance risk in `hybrid_query.ex`.** The `candidates` CTE is joined into
   `vector_search` before the `ORDER BY embedding <=> $1 LIMIT 200`. This is the right shape for
   correctness (filters must apply before ranking), but joining an arbitrary CTE ahead of the HNSW
   ordered scan can prevent Postgres from using the index's native top-N traversal — it may need to
   materialize/sort the full filtered candidate set before truncating to 200, especially once
   `source_id`/`repo`/`lang` are selective. Recommend `EXPLAIN ANALYZE` under realistic data volume,
   and consider `hnsw.iterative_scan` (pgvector ≥0.7) if plans show sequential/bitmap scans instead of
   index scans on `chunks_embedding_hnsw_idx`.

3. **No composite index for the actual hot-path filter combination.** The RRF query filters on
   `source_id`, `repo`, `lang` together (via `candidates`). Migration 3 only has single-column indexes
   on `source_type` (unused by this query), `repo`, `lang`, plus the leading-column coverage from the
   `[:source_id, :chunk_key]` unique index. Three separate single-column btrees force a `BitmapAnd`
   for combined filters. A composite `[:source_id, :repo, :lang]` (or `[:repo, :lang]`) index would
   serve the candidates CTE far more directly as data grows. `chunk.ex`'s moduledoc also says hot-path
   filters are `source_type/repo/lang`, but the actual query param is `source_id`, not `source_type` —
   worth reconciling doc vs. code.

## SUGGESTION

- `chunk_key` / `content_hash` are `:string` (varchar 255 default) — fine for hashes, but chunk keys
  derived from long file paths could exceed 255 chars; consider `:text` if natural keys aren't bounded.
- `pending_chunks` has no uniqueness guard on `(source, natural_key)`; if `*Sync` workers can re-enqueue
  the same file before `UpsertChunks` drains the row, duplicates will accumulate silently. Low risk
  given it's throwaway staging, but worth a comment/decision either way.
- `EnableExtensions.down/0` drops `vector`/`pg_trgm` unconditionally — correct given migration
  ordering (chunks table is torn down in an earlier `down` step first), but note this only works if
  migrations are always rolled back in strict reverse order (true for `mix ecto.rollback`, just don't
  hand-run `down` out of order).

## Confirmed Correct (no action needed)

- `vector(384)` used consistently in `chunks` and `pending_chunks`; no `vector(768)` found anywhere.
- `chunks_source_id_chunk_key_index` (from `unique_index(:chunks, [:source_id, :chunk_key])`) matches
  the `unique_constraint(..., name: :chunks_source_id_chunk_key_index)` in `Chunk.upsert_changeset/2` —
  correct ON CONFLICT target name for a future upsert.
- `tsv` generated column: literal `'english'` regconfig (required for STORED generated columns since
  regconfig via column ref isn't immutable), added via `execute/2` with explicit down SQL — reversible.
- HNSW + GIN indexes: `@disable_ddl_transaction true` set, built with `CREATE INDEX CONCURRENTLY`,
  `vector_cosine_ops` matches the `<=>` operator used in `hybrid_query.ex`. `maintenance_work_mem`
  bump is session-scoped and correctly placed outside a transaction.
- `on_delete` behaviors: `chunks.source_id` and `sync_states.source_id` → `:delete_all` (source purges
  both, matches doc); `secret_findings.chunk_id` → `:nilify_all` (audit outlives chunk re-ingestion) —
  all correct except item (1) above.
- `Chunk.tsv` field: `writable: :never`, `load_in_query: false`, backed by a pass-through
  `RetrievalNode.EctoTypes.TsVector` — correctly read-only, doesn't fight the generated column.
- RRF SQL: candidate pool 200/side, `UNION ALL` + `GROUP BY id` fusion, `Decimal.to_float/1` conversion
  handled in `HybridQuery.to_float/1`; all `$n` params correctly pinned (no string interpolation of
  user input — only the compile-time `@candidate_pool` constant is interpolated into SQL text).
- Schema/migration column name & type agreement checked across all 4 schemas — no mismatches found.

## Files Reviewed

- `/workspaces/slow-henry/priv/repo/migrations/20260714120001_enable_extensions.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120002_create_sources.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120003_create_chunks.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120004_create_chunk_search_indexes.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120005_create_sync_states.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120006_create_secret_findings.exs`
- `/workspaces/slow-henry/priv/repo/migrations/20260714120007_create_pending_chunks.exs`
- `/workspaces/slow-henry/lib/retrieval_node/retrieval/source.ex`
- `/workspaces/slow-henry/lib/retrieval_node/retrieval/chunk.ex`
- `/workspaces/slow-henry/lib/retrieval_node/retrieval/sync_state.ex`
- `/workspaces/slow-henry/lib/retrieval_node/retrieval/secret_finding.ex`
- `/workspaces/slow-henry/lib/retrieval_node/ecto_types/ts_vector.ex`
- `/workspaces/slow-henry/lib/retrieval_node/search/hybrid_query.ex`
