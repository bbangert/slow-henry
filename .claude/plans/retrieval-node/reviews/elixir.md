# Elixir Review: Phase 0-2 (postgrex_types, ts_vector, embedding, search, retrieval schemas, config)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 4

## Warnings

1. **`lib/retrieval_node/ecto_types/ts_vector.ex` moduledoc is stale/incorrect**: the doc says
   `dump/1` is a no-op "because the field is declared `load_only: true`" — but per the plan's own
   WHY-context, `load_only: true` is invalid in Ecto 3.14 and `chunk.ex` actually uses
   `writable: :never, load_in_query: false`. The docstring describes a field option that doesn't
   exist in this codebase. Fix the comment to reference the real opts so a future reader isn't sent
   looking for a `load_only` flag that was never implemented.

2. **`RetrievalNode.Retrieval.SyncState.changeset/2` and `Chunk.upsert_changeset/2` cast `:source_id`
   directly out of the attrs map** rather than requiring the caller to pass an already-scoped
   `source` struct (`put_assoc`) or an explicit `source_id` argument. Low risk today since only
   `Search`/`Ingest` call these internally, but it means any attrs bag handed to these changesets
   can silently reassign the parent FK. Worth tightening once `Ingest` lands in Phase 3 so the
   context function signature — not the attrs map — is what pins the association.

3. **`Search.hybrid_search/2` / `HybridQuery.search/1` use `Repo.query!` with no rescue/with-chain**,
   so any DB error (bad vector dimension, timeout, malformed `websearch_to_tsquery` input) crashes
   the calling process instead of surfacing `{:error, reason}`. This may be intentional
   ("let it crash", supervised MCP tool call boundary) but should be confirmed against how the MCP
   tool layer (Phase 3+) is expected to translate crashes into a client-facing error — UNVERIFIED
   without seeing that caller.

## Suggestions

1. **`Embedding` module hardcodes "384-dim" in two `@doc` strings** (`embed/1`, `dimensions/0`)
   while `dimensions/0` is meant to be the source of truth once real impls land. Consider dropping
   the magic number from the docs (or citing it as the *current default*) so the doc doesn't drift
   from the config-driven value in Phase 3.

## Notes (not findings)

- `Ecto.Changeset.unique_constraint(list_of_fields)` in `source.ex`/`chunk.ex` is valid (composite
  constraint support), verified against `deps/ecto/lib/ecto/changeset.ex` — no issue.
- `chunk.ex`'s `tsv` field opts (`writable: :never, load_in_query: false`) and the raw-SQL
  `HybridQuery` are both per the documented design deviations — not flagged.
- `Embedding`/`chunking_impl` pointing at not-yet-existing modules (`NxServingImpl`,
  `TreeSitterImpl`) is expected for Phase 0-2 — not flagged.
- No test files were located for these modules in this pass; confirm coverage exists before
  merging Phase 2 (not verified — scope was limited to the listed authored files).
