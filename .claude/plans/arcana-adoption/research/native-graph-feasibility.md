# Native code knowledge graph — feasibility research

Read-only research. No app code touched. All node-kind claims for §1 are
empirically verified by running the actual NIF (`mix run` against
`TreeSitterLanguagePack`) with one sample file per language — see the
S-expression dumps below — not guessed from grammar docs.

## 1. Tree-sitter API surface

`lib/retrieval_node/chunking/tree_sitter_impl.ex` wraps `deps/tree_sitter_language_pack`
(hex `tree_sitter_language_pack` 1.12.5, `mix.lock:59`), a Rustler NIF ("alef"-generated
bindings). Two API layers exist:

**Layer A — manual tree walking (fully exposed, what `tree_sitter_impl.ex` uses today).**
`TreeSitterLanguagePack.Native` (`deps/tree_sitter_language_pack/lib/tree_sitter_language_pack/native.ex:605-705`)
exposes `node_kind/1`, `node_kind_id/1`, `node_child_by_field_name/2`, `node_walk/1`,
`treecursor_goto_first_child/1`, `treecursor_goto_next_sibling/1`, `node_start_byte/1`,
`node_end_byte/1`, `node_to_sexp/1`, etc. — a complete cursor-based AST API with node kinds
and byte-range text extraction. This is everything `tree_sitter_impl.ex:137-217` already
uses to build chunk boundaries.

**Layer B — `process/1,2` "file intelligence" (higher-level, but incomplete for this
plan).** `TreeSitterLanguagePack.process/2` (`tree_sitter_language_pack.ex:104-108`) runs
a single parse and returns a `ProcessResult` struct with `structure` (functions/classes,
`StructureItem` — `structure_item.ex:9-19`, kinds in `structure_kind.ex:26-47`: function,
method, class, struct, interface, enum, module, trait, impl, namespace),
`imports` (`ImportInfo` — `import_info.ex:9-15`: source/items/alias/is_wildcard),
`exports`, `symbols` (definitions only), `comments`, `docstrings`, `diagnostics`, and
optional `chunks`. **Critically, `ProcessResult` has no `calls`/`references`/relationships
field at all** (`process_result.ex:28-40` enumerates every field). The underlying
extraction crate (`ts-pack-core`, referenced only via a local Cargo path at
`native/tree_sitter_language_pack_nif/Cargo.toml:32` that does not exist in this repo or
anywhere on disk — confirmed by `find`) ships as a precompiled binary; its extraction
logic is not inspectable, and it simply does not surface call-sites.

**No query-execution API.** The NIF exposes `get_highlights_query/1`, `get_tags_query/1`,
`get_locals_query/1`, etc. (`native.ex:80-193`), but these only return the *raw `.scm`
text* of bundled `highlights.scm`/`tags.scm`/`locals.scm` files — there is no
`query_new`/`query_matches`/`query_captures` binding anywhere in `native.ex` (grepped the
full file). So tree-sitter S-expression *query patterns* (the `(call_expression
function: (identifier) @name)` style) cannot be executed by this dependency at all; the
`tags.scm` text is unusable without a query engine we'd have to write ourselves.

**Conclusion for Q1: relationship extraction (call-sites, imports/aliases) must be hand-rolled
via Layer A manual tree walking**, following the exact same recursive-descent-over-named-children
pattern `tree_sitter_impl.ex:137-165` already uses for chunk boundaries. `process/2`'s
`structure`/`imports` could shortcut *entity definition* extraction for some cases, but
since we still need manual walking for calls, and want one parse pass (see §2), hand-rolling
everything through the existing traversal is simpler than mixing two APIs.

**7 configured languages** (`tree_sitter_impl.ex:34`): python, javascript, typescript, go,
rust, ruby, java. Empirically-verified node kinds (via `mix run` probe parsing one sample
file per language and dumping `TS.node_to_sexp/1`):

| Language | function/method def (existing, `tree_sitter_impl.ex:41-50`) | call expression | import/require |
|---|---|---|---|
| python | `function_definition`, `class_definition` | `call` (`function:` field is `identifier` or `attribute`) | `import_statement`, `import_from_statement` |
| javascript | `function_declaration`, `generator_function_declaration`, `class_declaration`, `method_definition` | `call_expression` (`function:` is `identifier` or `member_expression`) | `import_statement` |
| typescript | + `interface_declaration`, `type_alias_declaration`, `enum_declaration` | `call_expression` (same shape as JS) | `import_statement` |
| go | `function_declaration`, `method_declaration`, `type_declaration` | `call_expression` (`function:` is `identifier` or `selector_expression`) | `import_declaration` (contains `import_spec`) |
| rust | `function_item`, `struct_item`, `enum_item`, `trait_item`, `impl_item`, `mod_item` | `call_expression` | `use_declaration` |
| ruby | `method`, `singleton_method`, `class`, `module` | `call` (`method:` field; note: `require`/`require_relative` are **plain `call` nodes**, not a distinct import node kind — Ruby has no import statement) | none (see call) |
| java | `method_declaration`, `constructor_declaration`, `class_declaration`, `interface_declaration`, `enum_declaration`, `record_declaration` | `method_invocation` (`object:`/`name:` fields, or bare `name:` for unqualified calls) | `import_declaration` |

Callee-name resolution: for `call`/`call_expression`/`method_invocation`, the callee text
is either a direct `identifier`/`field_identifier` child (bare call) or the `attribute`/
`property_identifier`/`field:`/`name:` sub-field of a `member_expression`/`attribute`/
`selector_expression` (qualified call, e.g. `foo.bar(...)`) — only the same
`node_child_by_field_name` primitive already in use is needed to pull both shapes apart.

## 2. Current extraction — reusable traversal

`tree_sitter_impl.ex:137-165` does one cursor-based, single-pass, non-quadratic
(`named_children/1`, `tree_sitter_impl.ex:170-178`, uses `TreeCursor` siblings, not
indexed `node_named_child` re-scans) recursive descent that: (a) recognizes `@chunk_kinds`
nodes, (b) recurses into non-chunkable wrapper nodes carrying `scope` forward, (c) for a
chunkable node, either emits it as a leaf chunk or recurses to pull nested members
(`emit_or_recurse/5`, `tree_sitter_impl.ex:158-165`), building a `" > "`-joined breadcrumb
(`node_name/2`, `:191-196`, reads the grammar's `"name"` field).

This chunk-boundary walk **only visits chunk-boundary node kinds and their non-chunkable
wrappers** — it explicitly does not descend into a chunk body once emitted (`case
extract(child, ...) do [] -> emit ... end`, `:161-165`), so call expressions and imports
*inside* a leaf function body are never visited today. A second extraction pass that wants
calls/imports must walk the **full subtree of every node**, including inside chunk bodies —
a structurally different traversal (visit everything, not just boundary kinds) even though
it reuses the exact same node-walking primitives (`node_walk`/`treecursor_*`/`node_kind`/
`node_child_by_field_name`/`slice`).

**Recommendation: piggyback on the same parse, not a second `parser_parse` call.** The
expensive part (`TS.parser_parse(source)`, guarded inside the timeout/crash-isolated Task
at `tree_sitter_impl.ex:120-135`) already produces a `root` node; that root can be walked
twice in the same `parse_to_chunks/2` call — once for chunk boundaries (existing), once for
entities+calls (new) — without re-invoking the parser. Re-parsing would double NIF/Task
overhead and re-run the same crash/timeout risk twice per file for no benefit, since the
tree is already fully materialized in memory after the first `tree_root_node/1` call. The
natural seam is inside `parse_to_chunks/2` (`tree_sitter_impl.ex:120-135`): call a new
`extract_entities(root, source, language)` alongside the existing `extract(root, source,
language, [])`, both walking the one `root`.

## 3. Ingest hook — where graph rows flow, and the deletion lifecycle

Pipeline stages (`RetrievalNode.Ingest.PendingChunks` moduledoc,
`pending_chunks.ex:1-10`): `*Sync` → `insert_raw_all` (raw row) → `ChunkFiles.perform`
(`chunk_files.ex` at `lib/retrieval_node/ingest/workers/chunk_files.ex:41-126`) chunks +
`write_chunks` (staging rows, status `chunked`) → enqueues `EmbedBatch` → `EmbedBatch`
`set_embeddings` (status `embedded`) → `UpsertChunks.perform`
(`upsert_chunks.ex:48-63`) upserts into permanent `chunks` (`ON CONFLICT (source_id,
chunk_key)`, `upsert_chunks.ex:69-73`) and deletes the consumed staging rows in one
`Ecto.Multi` transaction.

**Entity/relationship rows belong in the same transaction as `UpsertChunks.perform`, not a
`pending_chunks`-style staging analog.** Reasoning: `pending_chunks` staging exists because
chunking and embedding are separable, retryable, crash-isolated Oban stages — but entity
extraction happens *during* the same tree-sitter parse as chunking (§2), so entity/call
records can be attached to each chunk's row *at chunk-write time*
(`ChunkFiles.chunk_attrs/4`, `chunk_files.ex:128-136`) and carried through `PendingChunks`
exactly like `chunk_content`/`context_breadcrumb` already are, then inserted alongside the
chunk row inside `UpsertChunks.insert_batches/3` (`upsert_chunks.ex:65-75`) — same
transaction, same idempotency story (`ON CONFLICT` on the chunk key), no new staging table
or extra Oban stage needed. Concretely: add `entities`/`relationships` jsonb (or normalized
row lists) to the chunk attrs map built in `chunk_attrs/4`, thread them through
`PendingChunk.chunk_changeset` and `PendingChunks.write_chunks/3`
(`pending_chunks.ex:139-160`), then in `UpsertChunks.to_chunk_entry/1`
(`upsert_chunks.ex:80-99`) additionally `insert_all` the entity/relationship rows scoped to
the just-upserted `chunk.id` inside the same `Ecto.Multi` (`upsert_chunks.ex:53-58`).

**Deletion lifecycle today:** `RepoSync.sync_changes/5` (`repo_sync.ex:79-93`) classifies
each diff entry as `:deleted` vs. present via `git diff --raw` status
(`git_mirror.ex:243,246`), and `delete_removed/2` (`repo_sync.ex:95-105`) runs one
`Repo.delete_all` on `Chunk` filtered by `source_id` + `metadata->>'path' IN (paths)` —
**deletion is by file path, not by chunk id**, and happens directly on the permanent
`chunks` table (no staging involved). The DB confirms `chunks.source_id` has `ON DELETE
CASCADE` from `sources` (`\d chunks` on the dev DB: `chunks_source_id_fkey ... ON DELETE
CASCADE`), and `secret_findings.chunk_id` already has `ON DELETE SET NULL` back to
`chunks.id` — i.e. **the schema convention for "child rows that die with their chunk" is
already an FK with `ON DELETE CASCADE` targeting `chunks.id`**, not a path-based delete.
So `entities`/`entity_mentions`/`relationships` should have `chunk_id` FKs with `ON DELETE
CASCADE` to `chunks`: a file-deletion event (`delete_removed/2`'s `Repo.delete_all(Chunk,
...)`) then automatically cascades and deletes graph rows for free, no new deletion code
path required.

**Caveat carried over unchanged, not introduced by this plan:** `UpsertChunks`' `ON
CONFLICT (source_id, chunk_key)` (`upsert_chunks.ex:69-73`) only *replaces* rows whose
`chunk_key` still exists after a re-chunk; if a file's internal chunk boundaries shift
(e.g. a function is deleted but the file itself remains), the now-orphaned old chunk row
for that removed function is **not** deleted by today's pipeline (no `chunk_key`
reconciliation step exists — confirmed by grep, no orphan-cleanup code anywhere in
`lib/`). Whatever graph rows attach via FK to that orphaned chunk row will silently persist
too, same as the orphaned chunk itself — this is a pre-existing gap in the base chunking
pipeline, not something the graph feature makes worse, but it is not "free" either; the
graph work doesn't need to fix it to be no-worse-than-status-quo.

## 4. Third RRF leg

`hybrid_query.ex` (`lib/retrieval_node/search/hybrid_query.ex`) is a raw-SQL two-CTE RRF
(k=60, `@rrf_k`) fusion (`hybrid_query.ex:37,66-107`). The load-bearing property, stated
explicitly in the moduledoc (`:10-28`) and proven by a live `pg_stat_user_indexes` check
the authors did: **every filter (`source_id`/`repo`/`lang`/`source_type`) must be inlined
into each leg's own `WHERE`**, never applied after fusion via a shared `candidates` CTE —
a referenced-twice CTE forces Postgres to materialize it and defeats both the HNSW and GIN
indexes (both legs fall back to seq scan). Each leg independently: filters, `ORDER BY
<rank-basis> LIMIT @candidate_pool` (200 default, `:44`), assigns `row_number()`.

A third `entity_search` leg would slot in as a third CTE with the *same shape* — its own
filtered, ranked, `LIMIT`-ed leg, unioned into `fused` by `id` (the `chunks.id`, since
entities are per-chunk) — not a join bolted onto the existing two legs:

```sql
entity_search AS (
  SELECT c.id, row_number() OVER (ORDER BY similarity(e.name, $9) DESC) AS rank
  FROM entity_mentions em
  JOIN entities e ON e.id = em.entity_id
  JOIN chunks c ON c.id = em.chunk_id
  WHERE e.name % $9  -- pg_trgm '%' similarity operator; needs a GIN trgm index on entities.name
    AND ($5::uuid IS NULL OR c.source_id = $5)
    AND ($6::text IS NULL OR c.repo = $6)
    AND ($7::text IS NULL OR c.lang = $7)
    AND ($8::text IS NULL OR c.source_type = $8)
  ORDER BY similarity(e.name, $9) DESC
  LIMIT #{@candidate_pool}
),
```
then `fused` becomes a 3-way `UNION ALL` (`hybrid_query.ex:91-98`) over
`vector_search`/`fts_search`/`entity_search`, unchanged `SUM(1.0 / (k + rank))` fusion
logic. This is exactly a CTE over `entity_mentions JOIN entities` with a **trigram** match
(`pg_trgm` is already enabled — `priv/repo/migrations/20260714120001_enable_extensions.exs:15`
— so `similarity()`/`%`/a `GIN (name gin_trgm_ops)` index are available with no new
extension) rather than exact match, since a code-search query like "where is
`process_payment` called" should tolerate near-misses (case, `snake_case`/`camelCase`,
partial qualification) the way FTS/vector legs already tolerate imprecision. Repeating the
same `c.source_id`/`c.repo`/`c.lang`/`c.source_type` filters inline (joined from `chunks`)
inside this leg's own `WHERE`, not after, is required to preserve the documented
index-pushdown property.

## 5. Prose (Jira/Drive) LLM extraction — corpus reality check

Queried the dev corpus directly (`psql -p 5433 -d retrieval_node_dev`, per user's memory
note that this port holds the real 81+-source corpus):

```
select source_type, count(*) from chunks group by 1;
 source_type | count
 git_repo    | 586418
```

**100% of the 586,418 chunks currently in the dev DB are `git_repo`; there are zero
`jira_project`/`drive_folder` chunks.** `select source_type, count(*) from sources group
by 1` confirms only `git_repo` sources (95) are configured — `jira.ex`/`drive.ex` ingest
code exists and is wired (`@source_types` map in `chunk_files.ex:31` already handles
`"jira"`/`"drive"`), but no Jira/Drive source has actually been synced into this instance
yet. So **the "% prose chunks" question has no real corpus answer today** — it's an
architecture decision to make ahead of data, not a measured proportion. (Of the git corpus,
also worth noting: only ~34.7% of chunks have a `lang` in the 7 tree-sitter-supported
languages — `lang IS NULL` accounts for 382,641/586,418 chunks, i.e. non-code files chunked
by `HeuristicImpl`, which native AST extraction cannot reach regardless of Jira/Drive.)

**Existing HTTP client pattern to model an LLM extraction client on:** `lib/retrieval_node/ingest/jira.ex`
uses `Req` (`req: "~> 0.5"`, `mix.exs:90`) built once via a `req/0` helper
(`jira.ex:119`) configured with the shared app-wide `Finch` pool (`finch:
RetrievalNode.Finch`, `jira.ex:116`) and a test-overridable `req_options/0` so `Req.Test`
can inject a plug instead of a real HTTP call (`jira.ex:122`, moduledoc `jira.ex:7-8`).
Rate-limit handling (429 + `retry-after` header, `jira.ex:90-113`) is handled manually with
Req's own retry disabled (`jira.ex:110-113`) — the same "disable library retry, own the
429/backoff decision explicitly" pattern would be the template for an LLM API client
(track token-bucket/rate-limit headers, not Req's generic retry).

## 6. Cross-repo entity identity

The schema already scopes chunks two ways: `source_id` (FK to `sources`, i.e. one git
repo/Jira project/Drive folder — binary_id UUID, `chunk.ex:38`) and `repo` (denormalized
string slug, btree-indexed, `chunk.ex:17`, populated from `Source.mirror_slug/1`,
`source.ex:49-51`). Both are already first-class hybrid-query filters
(`hybrid_query.ex:61-62`).

**Recommendation: scope entities per-`source_id`, not globally.** A Python function named
`setup` (or `main`, `handle`, `process`) exists in most of the 91 git repos in this corpus
independently — a global `(language, name)` key would silently merge unrelated functions
across repos into one graph node, corrupting call-graph traversal (a call to `setup()` in
repo A would resolve to `setup` defined in repo B). Recommended uniqueness key:

```
UNIQUE (source_id, language, qualified_name)
```

where `qualified_name` is derived from the same breadcrumb machinery chunking already
builds (`Breadcrumb.build/2` used in `chunk_attrs/4`, `chunk_files.ex:133`, and the
`" > "`-joined `scope` list in `tree_sitter_impl.ex:159,204`) plus the file path from
`chunk.metadata->>'path'` — e.g. `"lib/foo.py::Class.method"` — so two same-named methods
on different classes, or in different files of the *same* repo, still don't collide.
`source_id` (not the denormalized `repo` string) should be the scoping key since it's the
actual FK/uniqueness anchor Postgres can enforce and cascade-delete against
(`chunks_source_id_fkey ... ON DELETE CASCADE` already established in §3); `repo` is a
convenience filter column, not an identity key. If cross-repo "same logical function,
different repo" linkage is ever wanted (e.g. "find all repos implementing this interface"),
that's a *separate*, optional `canonical_name` column for fuzzy grouping post-hoc — never
the primary key, to avoid the collision risk above.

## Summary of key files (evidence index)

- `lib/retrieval_node/chunking/tree_sitter_impl.ex` — chunk-boundary traversal to extend/reuse (§1, §2)
- `deps/tree_sitter_language_pack/lib/tree_sitter_language_pack/native.ex` — full exposed NIF surface, no query-exec API (§1)
- `deps/tree_sitter_language_pack/lib/tree_sitter_language_pack/process_result.ex`, `structure_item.ex`, `import_info.ex` — `process/2`'s fields, no calls/relationships (§1)
- `lib/retrieval_node/ingest/pending_chunks.ex`, `lib/retrieval_node/ingest/workers/chunk_files.ex`, `lib/retrieval_node/ingest/workers/upsert_chunks.ex`, `lib/retrieval_node/ingest/workers/repo_sync.ex` — pipeline + deletion lifecycle (§3)
- `lib/retrieval_node/retrieval/chunk.ex`, `lib/retrieval_node/retrieval/source.ex` — FK/cascade conventions (§3, §6)
- `lib/retrieval_node/search/hybrid_query.ex` — RRF SQL to extend (§4)
- `priv/repo/migrations/20260714120001_enable_extensions.exs` — `pg_trgm` already enabled (§4)
- `lib/retrieval_node/ingest/jira.ex` — Req/Finch client pattern (§5)
- dev DB (`psql -p 5433 retrieval_node_dev`) — corpus is 100% `git_repo`, 0% Jira/Drive today (§5)
