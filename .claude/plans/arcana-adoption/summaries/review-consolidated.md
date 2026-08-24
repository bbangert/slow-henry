# Review Consolidation: arcana-adoption

**Strategy**: Compress  
**Input**: 6 files, ~7k tokens  
**Output**: ~3.5k tokens (50% reduction)

---

## Requirements Coverage & Verification

| Item | Status |
|---|---|
| Reranking serving (NxServingImpl, supervised, passage truncation) | ✅ MET |
| Graph tables (entities, mentions, edges, cascades, trigram GIN) | ✅ MET |
| Graph extraction + staging + persistence (batching per param limits) | ✅ MET |
| Graph GC + lifecycle | ✅ MET |
| Hybrid query entity leg (RRF + weights) | ✅ MET |
| MCP tools (related_code, semantic_search graph opt) | ✅ MET |
| LLM extractor stub + Req pattern reference | ✅ MET |
| **Verification**: compile ✓ \| format ✓ \| credo ✓ \| dialyzer ✓ \| sobelow ✓ \| unit tests 276 ✓ \| integration 84 ✓ | ✅ PASS |
| Backfill mix task (code done; execution blocked per dev-DB access) | ⚠️ PARTIAL |
| EXPLAIN ANALYZE on 5433 (blocked per plan) | ⚠️ PARTIAL |

---

## BLOCKERs

### 1. Unbounded edge fan-out in graph traversal (memory DoS)
- **Location**: `lib/retrieval_node/graph.ex:304-310` (`edges_query/4`), driven by `:240-280`, consumed by `mcp/tools/related_code.ex:91-98`
- **Failure scenario**: Single MCP call `{"entity": "get", "relation": "callers", "hops": 2}` on a hot utility symbol (e.g., `log`, `get`, `main`) in a 91-repo corpus:
  1. Seed 50 entities via `find_entities` limit
  2. Load **every** edge (uncapped) pointing at them — six-figure in-degree per hot symbol
  3. Feed all hop-1 ids (uncapped) back into hop-2 traversal with no deduplication truncation
  4. Full `Entity` structs loaded for the union
  5. All rows land in BEAM heap; repeated calls OOM the node (which hosts ~1.2 GB embedding + 91 MB rerank, already thin)
  6. No rate limiting exists on MCP surface
- **Fix sketch**:
  ```elixir
  @edge_fanout_limit 500        # per edges_query call
  @hop2_frontier_limit 100      # seeds carried into hop 2
  
  defp edges_query(ids, kind, filter_field, select_field) do
    from(e in EntityEdge,
      where: e.kind == ^kind and field(e, ^filter_field) in ^ids,
      select: %{entity_id: field(e, ^select_field), weight: e.weight},
      order_by: [desc: e.weight],
      limit: @edge_fanout_limit
    )
  end
  
  # hop2: Enum.sort_by(&(-&1.weight)) |> Enum.take(@hop2_frontier_limit) before traversal
  ```

### 2. Concurrent UpsertChunks deadlock on entity/edge upserts (Oban)
- **Location**: `lib/retrieval_node/graph.ex:611-624` (`write_edges`), `:417-425` (`upsert_definitions`); `lib/retrieval_node/ingest/workers/upsert_chunks.ex:60-73`
- **Failure scenario**: Two concurrent `UpsertChunks` jobs (different files, same source, both under `:upsert` concurrency=5) each `insert_all` entities/edges with `on_conflict: {:replace, ...}` against the same unique index (`[:source_id, :language, :qualified_name]` / `[:source_entity_id, :target_entity_id, :kind]`). If batch A contains conflicting keys {X, Y} and batch B contains {Y, X}, each acquires a row lock on its first key then blocks waiting for the other → deadlock, one aborted by Postgres.
  - **Plausible in real corpora**: shared module names, common function names like `init`/`start`
- **Fix sketch**: Sort each `insert_all` batch's entries by the conflict-target tuple before writing:
  ```elixir
  # write_edges/2
  staged_rows
  |> Enum.sort_by(&{&1.source_id, &1.target_entity_id, &1.kind})
  |> insert_all(...)
  
  # upsert_definitions/2
  entries |> Enum.sort_by(&{&1.source_id, &1.language, &1.qualified_name}) |> insert_all(...)
  ```

### 3. TOCTOU race: force_full_resync_git_sources cleared by in-flight RepoSync (Oban)
- **Location**: `lib/retrieval_node/ingest.ex:91-103` (`force_full_resync_git_sources`); `lib/retrieval_node/ingest/workers/repo_sync.ex:56-93`
- **Failure scenario**: 
  1. `RepoSync.perform/1` reads `last_sha` from `sync_state.cursor` at start
  2. `clear_sync_cursor!/1` fires during sync (from backfill task)
  3. `RepoSync`'s `unique` constraint (keys: `[:source_id]`) means a new backfill job dedups onto the already-running one instead of creating a fresh one
  4. When in-flight job finishes, it calls `advance_watermark(sync_state, new_sha)` using stale `sync_state` struct loaded before the clear → silently re-establishes "synced to HEAD" cursor
  5. Result: backfill reports source as successfully enqueued; actually no-ops silently
- **Fix sketch** (either):
  - (a) Have `RepoSync.perform/1` re-fetch `sync_state` immediately before `advance_watermark` (read-modify-write + `WHERE cursor = <the one we read>` optimistic check inside same transaction)
  - (b) Have `force_full_resync_git_sources` check for executing/scheduled `RepoSync` first and skip/wait rather than assuming its own `Oban.insert` guarantees a fresh run

---

## WARNINGs

### 1. Partial function clauses in graph kind conversion (will crash on LLM extractor seam)
**Merged from**: elixir-reviewer (warnings 1 + 2 on kind functions), oban-reviewer (suggestion on function clause error), security-reviewer (§5 on changeset bypass)

- **Location**: `lib/retrieval_node/graph.ex:453-454` (`ref_entity_kind/1`), `:608-609` (`edge_kind/1`), `:566-567` (`mention_kind/1`) + `lib/retrieval_node/graph/extractor/tree_sitter.ex:453-454` (entity.kind extraction) + `lib/retrieval_node/graph.ex:405-482, 537-577, 597-643` (graph writes via `insert_all`, never call changeset)
- **Current state (safe)**: TreeSitter extractor only emits `:call`/`:import` references; entity kinds are validated by `entity_kind_for/2`. Graph writes bypass changeset but only trusted in-process TreeSitter writes today.
- **Failure scenario (at LLM extractor seam)**: `Graph.Extractor.LLM` is a documented seam for model-generated entity names. If LLM emits an unknown `kind` (or future extractor adds a third ref kind), partial function raises `FunctionClauseError` deep inside `UpsertChunks` transaction — ingest-wide crash instead of clear error; no changeset validation catches malformed `qualified_name` length/shape.
- **Fix sketch**:
  - Add catch-all clauses to `ref_entity_kind/1`, `edge_kind/1`, `mention_kind/1` that raise `ArgumentError` (not `FunctionClauseError`) with the bad value
  - Before LLM extractor lands: validate staged graph rows — `qualified_name` is a binary ≤512 bytes, `kind` is in the Ecto.Enum allowlist (reuse `kind_atom/3`), drop-with-log rather than raise on bad row
  - Add compile-time or test assertion that `entity_kind_for/2` outputs match `Entity.kind`'s enum `values:`

### 2. LIKE-metacharacter injection in entity suffix search + trigram DoS
**Merged from**: security-reviewer (§3 LIKE injection, §4 trigram DoS)

- **Location**: `lib/retrieval_node/graph.ex:204-205` (`ilike(e.qualified_name, ^("%." <> name))`), `:207-212` (word_similarity), `mcp/tools/related_code.ex:37-41` (unbounded entity field), `hybrid_query.ex:300-307` (significant_terms no max length)
- **Failure scenario A (scope broadening)**: `{"entity": "%"}` matches every dotted qualified name corpus-wide; tier-2 ILIKE `'%.%'` with no escape. `related_code` returns up to 50 chunk snippets (~1000 chars each) from any repo (repo/lang filters optional). Repeat with `%a%`, `%b%`… to walk the corpus undirected (not auth bypass, but tool becomes code dumper).
- **Failure scenario B (CPU DoS)**: Pattern with no extractable 3-char trigram (`%`, `_`, `a%`, `%_%_%_%...`) is index-unusable → sequential scan + per-row ILIKE backtracking on 586k-chunk entities table, worse with `filter_repo EXISTS` subquery running per row. Or: eight 1 MB terms in `semantic_search` with `graph: true` cause `word_similarity` to re-evaluate on every candidate row.
- **Fix sketch**:
  ```elixir
  # graph.ex suffix_name_query
  defp escape_like(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")
  
  defp suffix_name_query(base, name) do
    pattern = "%." <> escape_like(name)
    from(e in base,
      where: fragment("? ILIKE ? ESCAPE '\\'", e.qualified_name, ^pattern))
  end
  
  # related_code.ex execute/2
  @max_entity_length 256
  defp normalize_entity(e) when byte_size(e) <= @max_entity_length, do: {:ok, e}
  
  # hybrid_query.ex significant_terms/1
  @max_term_length 128
  |> Enum.reject(&(String.length(&1) < @min_term_length or String.length(&1) > @max_term_length))
  ```
  - Note: `ilike/2` doesn't accept `ESCAPE`, so `fragment` form is required for backslash escape

### 3. Integration tests excluded from default CI run (tree-sitter extraction coverage missing)
- **Location**: `test/retrieval_node/graph/extractor/tree_sitter_test.exs:7` (`@moduletag :integration`)
- **Issue**: Entire file excluded from default `mix test`; only test coverage for TreeSitter extraction (callee resolution, scoping, import aliasing) — new, non-trivial business logic — but CI never runs it (test_helper.exs:4 excludes :integration). Per review brief: "CI would never run them" check — this is exactly that.
- **Fix**: Either (a) add small non-integration smoke test on fake/pre-built AST fixture (no NIF), or (b) wire `--include integration` into CI pipeline and document the decision so it's not accidental.

### 4. Trigram entity search not source-scoped before JOIN chunks
- **Location**: `lib/retrieval_node/search/hybrid_query.ex:159-183` (entity leg), `e.qualified_name %> ANY($9::text[])` trigram match
- **Issue**: Filtered by source_id/repo only *after* three-way join via `@filters_c` on chunks. For large multi-repo corpus, entity-name trigram scan runs unfiltered across every source's entities before narrowing, unlike vector/FTS legs which filter chunks directly. Per moduledoc caveat "pending EXPLAIN validation" — not re-litigating the shipped-off-by-default decision, but **flagging so eventual EXPLAIN pass specifically checks** whether pushing `c.source_id`/`repo` into the entities/entity_mentions join order is needed.

### 5. Graph edge/mention deletion races and transaction timeouts
**Merged from**: oban-reviewer (warnings 2 + 3)

- **Location**: `lib/retrieval_node/graph.ex:70` / `:513-522` (`delete_stale_mentions` + `write_edges`); `lib/retrieval_node/ingest/workers/graph_gc.ex` (no timeout); `lib/retrieval_node/ingest/workers/upsert_chunks.ex:60-73` (transaction duration)
- **Issue A (edge race)**: Verify extractor's `references[].from` field is *always file-scoped*, never points at another file of same source. If it can, two concurrent jobs could both `delete_all` + reinsert edges for the same `source_entity_id`, causing lost-update race (not double-count, but one job's edges clobbered).
  - **Fix**: Confirm in `graph/extractor.ex` documentation, or add assertion `Enum.uniq_by(staged_rows, & &1.source_id) |> length() == 1`
- **Issue B (timeout)**: `Graph.gc_orphaned_entities/1` loops in 10k batches with no upper bound. On multi-million-row orphan backlog (plausible post-backfill or after large repo deletion), single job could run for hours occupying one of 5 `:upsert` slots, competing with latency-sensitive `UpsertChunks`.
  - **Fix**: Add `timeout/1` callback (e.g., 30–60 min) to gracefully `{:snooze, _}`-and-resume, or split into chunked/looping Oban job
- **Issue C (no explicit timeout)**: Pathological files drive large entity/mention/edge batches inside `UpsertChunks` transaction, holding row locks on `entities`/`entity_edges` for full duration. Combined with BLOCKER #2 deadlock, increases collision window. No explicit statement/transaction timeout set (relies on Postgres defaults) — confirm default is acceptable given `:upsert` concurrency 5 and `max_attempts: 5`.

---

## SUGGESTIONs

### Refactoring & Shared Helpers
- **Kind atom conversion pattern** (elixir): `kind_atom/2` and `UpsertChunks.to_enum/2` are near-identical. Extract `RetrievalNode.EctoEnum.from_dump!/3` shared helper; same pattern will recur for next Ecto.Enum staging round-trip.
- **Graph fixtures** (testing): Hoisting `RetrievalNode.GraphFixtures` support module (mirroring `test/support/fake_chunking_impl.ex`'s pattern) cuts ~80 lines of duplicated fixture code across 4 test files.

### Defensive Checks
- **@candidate_pool compile-time guard** (security): `hybrid_query.ex:62` interpolates config directly into SQL. Add guard:
  ```elixir
  @candidate_pool (case Application.compile_env(:retrieval_node, :rrf_candidate_pool, 200) do
                     n when is_integer(n) and n > 0 -> n
                     other -> raise "rrf_candidate_pool must be positive integer, got #{inspect(other)}"
                   end)
  ```
- **Rerank query + model pinning** (security): Truncate untruncated query text (not just passages) before pairing with ~50 passages (`nx_serving_impl.ex:37`); pin reranker model revision (`config/config.exs:91` loads HF repo HEAD with no revision pin).
- **Rerank scores length assertion** (elixir): `nx_serving_impl.ex:41-43` asserts (comment only) serving returns list same length as pairs. Add defensive `length(scores) == length(passages)` check or remove ambiguous comment.

### Discoverability & UX
- **Backfill confirmation prompt** (security): `rn.graph.backfill` clears every source's watermark and re-embeds entire corpus (hours of work) with **no confirmation**. Gate destructive branch behind `Mix.shell().yes?/1` or `--force` switch; keep `--status` prompt-free.
- **definition_snippets repo/lang filter** (security): `related_code.ex:96` passes entity ids without `repo`/`lang` scope. Thread filters into snippet query so repo-scoped calls don't leak cross-repo snippets.
- **collect_definitions order dependency** (elixir): Comment says "last write wins" but depends on `staged_rows` iteration order, not timestamp. Add note explaining this for future callers who might reorder rows.
- **Limit test assertion** (testing): Seed >50 same-suffix entities to make `:limit` cap meaningful (`graph_test.exs:502-511`), or drop claim from test name.

---

## Coverage

| File | Represented | Key Findings |
|---|---|---|
| elixir.md | Yes | 4W (partial functions, trigram scope, order dependency, rerank assertion) + 3S (kind helper, fixture hoisting, defensive checks) |
| security.md | Yes | 1B (unbounded edges) + 3W (LIKE injection, trigram DoS, changeset bypass) + 4S (config guard, query truncate, model pin, backfill prompt) |
| testing.md | Yes | 1C (integration tests), 4W (rerank edge cases, hops validation, lang filter, limit assertion) + 1S (fixture hoisting) |
| oban.md | Yes | 2B (deadlock, TOCTOU race) + 3W (edge scope, timeout, transaction size) + 2S (kind functions, GC unique comment) |
| verification.md | Yes | All checks passed (compile, format, credo, dialyzer, sobelow, 276 unit + 84 integration tests) |
| requirements.md | Yes | 17 MET, 3 PARTIAL (backfill execution blocked, EXPLAIN blocked, live smoke blocked), 4 UNCLEAR (cannot execute in this environment) |

---

## Deconfliction Summary

1. **Graph kind functions + changeset bypass + LLM seam** → merged into single WARNING #1, crediting elixir/oban/security reviewers. Rating: WARNING (latent until LLM lands, current TreeSitter use is safe).
2. **LIKE metacharacter + trigram DoS** → merged into single WARNING #2, separate from WARNING #4 (trigram scope) because scope is a design decision pending EXPLAIN, while injection/DoS are actionable fixes.
3. **Edge/mention races + timeouts** → merged into single WARNING #5 because all three (race scope, GC timeout, transaction duration) are interconnected hazards in the same subsystem (graph writes).

---

## Priority Order (per review orchestrator)

1. **BLOCKER #1** (unbounded edges) — add limits + cap hop-2 frontier
2. **BLOCKER #2** (deadlock) — sort batches by conflict key
3. **BLOCKER #3** (TOCTOU race) — re-fetch state or gate backfill
4. **WARNING #1** (kind functions + changeset bypass) — add catch-alls + pre-LLM validation
5. **WARNING #2** (LIKE + DoS) — escape patterns + length bounds
6. **WARNING #3** (integration tests) — add smoke test or wire CI
7. **WARNING #4 & #5** (scope + races + timeouts) — confirm edge scope, add GC timeout, confirm transaction defaults
