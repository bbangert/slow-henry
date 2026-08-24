# Security Review: arcana-adoption (rerank + code knowledge graph + 2 MCP surfaces)

Scope: new/changed code only. MCP LAN-only/no-auth is accepted pre-existing risk;
findings below are about the *new* tools widening blast radius or adding unbounded
work, not about the missing auth itself.

**Verdict: no injection or secret-leak BLOCKER. 1 BLOCKER-class resource
amplification, 3 WARNINGs, 4 SUGGESTIONs.**

---

## 1. sobelow_skip claim in `hybrid_query.ex` — VERIFIED ACCURATE

`lib/retrieval_node/search/hybrid_query.ex:252-256` claims "every runtime value
travels as a bind parameter". I traced both SQL variants:

| Interpolation site | Source | Compile-time? |
|---|---|---|
| `@candidate_pool` (×3 legs, `:130,:143,:181`) | `Application.compile_env/3` default 200 (test 5) | yes |
| `@mention_weight_definition/_call/_import` (`:168-170`) | literal module attrs | yes |
| `@filters_bare` / `@filters_c` (`:108,:116`) | literal strings, `$5..$8` placeholders | yes |
| `@vector/@fts/@entity/@fused_*/@select` | composed from the above at compile time | yes |

Runtime values, all bound: `$1` embedding (`Pgvector.new/1`), `$2` text_query,
`$3` `@rrf_k`, `$4` clamped top_k, `$5..$8` filters (nil-safe casts),
`$9` terms as `::text[]`, `$10` weight from `Application.get_env`.
`@sql`/`@sql_graph` are the only two strings ever reaching `Repo.query!/2`
(`:286`), selected by a boolean — no caller-influenced SQL text. `websearch_to_tsquery('english', $2)`
is parameterized, so MCP `semantic_search` query text cannot reach SQL syntax.
**Injection from MCP query text: not reachable.** Skip annotation is justified.

### SUGGESTION 1.1 — assert the interpolated config is an integer
`hybrid_query.ex:62`. `@candidate_pool` is interpolated directly into SQL. Config
is trusted today, but a string value (`"5; --"`) would silently become SQL text
and the sobelow skip now suppresses the alarm. Cheap compile-time guard:

```elixir
@candidate_pool (case Application.compile_env(:retrieval_node, :rrf_candidate_pool, 200) do
                   n when is_integer(n) and n > 0 -> n
                   other -> raise "rrf_candidate_pool must be a positive integer, got #{inspect(other)}"
                 end)
```

---

## 2. BLOCKER — unbounded edge fan-out in `related_entities/3` (memory DoS)

- **Location**: `lib/retrieval_node/graph.ex:304-310` (`edges_query/4`), driven by
  `graph.ex:240-280` and `mcp/tools/related_code.ex:91-98`
- **Issue**: `edges_query/4` does `Repo.all/1` with **no LIMIT**. The
  `@related_entities_limit 50` cap is applied only *after* the whole traversal
  (`graph.ex:273`). One `related_code` call can therefore:
  1. match up to 50 seed entities (`find_entities` limit),
  2. load **every** `entity_edges` row pointing at them — a hot utility symbol
     (`log`, `get`, `new`, `main`) in a 91-repo corpus can have a six-figure
     in-degree, and 50 such seeds multiply it,
  3. with `hops: 2`, feed *all* of those hop-1 ids (uncapped —
     `dedup_max_weight/1` dedups but does not truncate) back into
     `field(e, ^filter_field) in ^ids`, producing a huge parameter array and a
     second, larger fan-out,
  4. then `load_entities/1` (`graph.ex:314`) loads the full `Entity` structs for
     the union.
- **Exploit**: `{"entity": "get", "relation": "callers", "hops": 2}` — a single
  legitimate-looking tool call. All rows land in BEAM heap; repeated calls OOM the
  node (which also hosts the ~1.2 GB embedding + 91 MB rerank servings, so memory
  headroom is already thin). No rate limiting exists on the MCP surface.
- **Fix sketch**: cap inside SQL and cap the hop-2 frontier:

```elixir
@edge_fanout_limit 500   # per traversal query
@hop2_frontier_limit 100 # seeds carried into hop 2

defp edges_query(ids, kind, filter_field, select_field) do
  from(e in EntityEdge,
    where: e.kind == ^kind and field(e, ^filter_field) in ^ids,
    select: %{entity_id: field(e, ^select_field), weight: e.weight},
    order_by: [desc: e.weight],
    limit: @edge_fanout_limit
  )
  |> Repo.all()
end

# hop 2
hop1
|> Enum.sort_by(&(-&1.weight))
|> Enum.take(@hop2_frontier_limit)
|> Enum.map(& &1.entity_id)
|> traverse_edges(relation)
```

Ordering by `weight desc` before the limit keeps the result semantically the same
for the top-50 that survive `graph.ex:273`.

---

## 3. WARNING — LIKE-metacharacter injection in `find_entities` suffix tier

- **Location**: `lib/retrieval_node/graph.ex:204-205`
  (`ilike(e.qualified_name, ^("%." <> name))`)
- **Issue**: `name` is the raw MCP `entity` param. `%`, `_` and `\` are not
  escaped. The codebase's own precedent escapes them —
  `lib/retrieval_node/bench/runner.ex:162`:
  `defp like_pattern(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")`
  (used at `runner.ex:149,156`). The new code diverges from that convention.
- **Exploit A (scope broadening / bulk extraction)**: `{"entity": "%"}` → tier 1
  (exact) misses, tier 2 runs `ILIKE '%.%'`, matching *every* dotted qualified
  name corpus-wide. `related_code` then hands those ids to
  `Graph.definition_snippets/2` (`related_code.ex:87`), returning up to 50
  chunk-content snippets of ~1000 chars each. A caller who is supposed to be
  asking "where is X defined" instead pages arbitrary source out of any repo, and
  `repo`/`lang` filters are optional so nothing narrows it. Repeat with
  `%a%`, `%b%`… to walk the corpus. (Not an authz bypass — there is no authz — but
  it converts a symbol-lookup tool into an undirected code dumper.)
- **Exploit B (CPU DoS)**: `entities_qualified_name_trgm_idx` is
  `gin (qualified_name gin_trgm_ops)`
  (`priv/repo/migrations/20260714140001_create_graph_tables.exs:21-24`). A pattern
  with no extractable 3-char trigram (`%`, `_`, `a%`, `%_%_%_%_%_%`) is
  index-unusable → sequential scan + per-row ILIKE backtracking over an
  entities table sized for a 586k-chunk / 91-repo corpus. Worse when combined
  with the `filter_repo/2` `EXISTS` subquery (`graph.ex:188-200`), which then runs
  per surviving row.
- **Fix**:

```elixir
defp suffix_name_query(base, name) do
  pattern = "%." <> escape_like(name)
  from(e in base,
    where: fragment("? ILIKE ? ESCAPE '\\'", e.qualified_name, ^pattern))
end

defp escape_like(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")
```

Note `ilike/2` does not accept `ESCAPE`, so the `fragment` form is required for
the backslash escape to be honored (still fully parameterized).
- **OWASP**: A03 (Injection — LIKE pattern), A04 (Insecure Design — unbounded query).

---

## 4. WARNING — no length bound on caller-supplied entity/term text (trigram DoS)

- **Locations**: `mcp/tools/related_code.ex:37-41` (`field(:entity, :string)`, no
  max), `graph.ex:207-212` (`%>` + `word_similarity` on that raw value),
  `hybrid_query.ex:300-307` (`significant_terms/1` caps *count* at 8 and *minimum*
  length at 3, but has **no maximum term length**)
- **Issue**: pg_trgm must extract the trigram set of the query string on every
  comparison. A 1 MB `entity` value yields ~1 M trigrams; `graph.ex:210` also
  computes `word_similarity(name, qualified_name)` in `ORDER BY`, i.e. per
  candidate row. Via `semantic_search` with `graph: true`, eight 1 MB tokens ride
  in `$9::text[]` and `hybrid_query.ex:166`'s correlated
  `(SELECT max(word_similarity(t, e.qualified_name)) FROM unnest($9::text[]) t)`
  re-evaluates all eight per candidate row.
- **Exploit**: single POST with `entity` = `String.duplicate("a", 1_000_000)`;
  or `semantic_search` with `graph: true` and a multi-MB query body. Postgres CPU
  and work_mem spike; no timeout or rate limit on the path.
- **Fix**: bound at the boundary (defense in depth, both places):

```elixir
# related_code.ex execute/2, before run/5
@max_entity_length 256
defp normalize_entity(e) when byte_size(e) <= @max_entity_length, do: {:ok, e}
defp normalize_entity(_), do: {:error, "entity too long — max #{@max_entity_length} bytes"}

# hybrid_query.ex significant_terms/1
@max_term_length 128
|> Enum.reject(&(String.length(&1) < @min_term_length or String.length(&1) > @max_term_length))
```

A `statement_timeout` on the query pool would also blunt this class generally.

---

## 5. WARNING — graph writes bypass the changeset (Iron Law 1, at the LLM seam)

- **Location**: `lib/retrieval_node/graph.ex:405-482, 537-577, 597-643` —
  `insert_all` with hand-built maps; `Graph.Entity.changeset/2`
  (`graph/entity.ex:40-46`) is never called on this path
- **Issue**: `qualified_name` comes from `Map.fetch!(entity, "qualified_name")` on
  the `graph` jsonb with no type/length/shape validation. Today the only producer
  is the in-process tree-sitter chunker (trusted), so this is latent — but
  `Graph.Extractor.LLM` (`graph/extractor/llm.ex`) is a documented seam for
  **model-generated** entity names, i.e. externally influenced content
  (prompt-injectable Jira/Drive prose) flowing straight into `insert_all`.
  Related brittleness on the same path: `ref_entity_kind/1` (`graph.ex:453-454`),
  `mention_kind/1` (`:566-567`) and `edge_kind/1` (`:608-609`) have no catch-all
  clause — an unexpected `kind` is a `FunctionClauseError` inside the
  `UpsertChunks` transaction, i.e. a poison-pill job that burns all attempts.
- **Fix**: before the LLM extractor lands, validate staged graph rows —
  `qualified_name` is a binary of bounded length (e.g. ≤ 512 bytes), `kind` is in
  the enum allowlist (reuse `kind_atom/3`, which is already a correct allowlist),
  and drop-with-log rather than raise on a bad row.

---

## 6. Secrets / scrubbing order — CONFIRMED CORRECT

Traced `lib/retrieval_node/ingest/workers/chunk_files.ex:49-68`:
`Scrubber.scrub/2` runs first; on `{:ok, result}` the pipeline calls
`Chunking.chunk_with_graph(content = result.redacted_content, ...)` (`:55, :66`),
so entities/references are derived from **post-scrub** text — they cannot carry
un-redacted secrets. Fail-closed `{:cancel, _}` path still reaps the raw staging
row (`:57-62`). `graph` jsonb only ever holds `qualified_name`/`kind`/`from`
(`:187-191`), never content.

`Graph.definition_snippets/2` (`graph.ex:336-355`) returns `chunk.content`, which
is the same post-scrub content `get_file` already serves; it is truncated to 20
lines / 1000 chars. No `secrets_status` filter exists anywhere on the read side
(`grep secrets_status lib/` → writes only) — **pre-existing**, and defensible
since `:redacted` means the secret was already replaced. One line, no deep dive:
if you ever add a scrub mode that indexes unredacted content, both `get_file`
and `definition_snippets` need a `secrets_status` gate.

### SUGGESTION 6.1 — `definition_snippets` ignores the caller's repo/lang filter
`related_code.ex:96` passes related-entity ids straight through, and
`definition_snippets/2` has no repo/lang predicate. A `repo`-scoped
`related_code` call can therefore return snippets from *other* repos (reached via
cross-repo edges). Not a boundary violation here, but it makes the `repo` filter
misleading; thread `repo`/`lang` into the snippet query.

---

## 7. Bounded-and-clean areas (verified, no action)

- **`hops` validation**: double-guarded — `related_code.ex:124-126`
  (`hops in [1, 2]`, else error reply) and `graph.ex:240-241`
  (`hops in [1, 2]` function guard). No unbounded recursion.
- **`relation` / `source` params**: both resolved through literal maps
  (`related_code.ex:28-34`, `semantic_search.ex:24`) with an error branch — no
  `String.to_atom/1` anywhere in the new code (grepped). Iron Law 3 upheld.
- **Limit clamping**: `clamp_top_k/1` `hybrid_query.ex:328-329` (max 100),
  `clamp_find_limit/1` `graph.ex:180-181` (max 50), `clamp_snippet_limit/1`
  `graph.ex:357-358` (max 50). Note `find_entities`' `:limit` is not exposed on
  the MCP tool at all, so only the defaults are reachable externally.
- **Rerank path bounded**: candidate pool `max(50, top_k)` then clamped to 100
  (`search.ex:63` → `hybrid_query.ex:259`); each passage byte-capped at 2000
  (`reranking/nx_serving_impl.ex:33,59-67`); serving batch_size 16 and
  `sequence_length [256, 512]` compiled (`config/config.exs:90-94`), so
  tokenization is bounded. `Nx.Serving` provides the backpressure.
- **GC batching**: `gc_orphaned_entities/1` (`graph.ex:102-132`) is
  operator/cron-driven only, uses a bounded subquery, no user input.
- **No `raw/1`, no `binary_to_term`, no `File.read` of user paths, no new
  `fragment` string interpolation** in the changed set.

### SUGGESTION 7.1 — truncate the rerank query, not just passages
`nx_serving_impl.ex:37` pairs the **untruncated** query with each of ~50
passages, so a 5 MB `semantic_search` query is tokenized 50 times before the
tokenizer discards it at the token budget. The passage-side rationale in the
`@max_passage_bytes` comment (`:24-32`) applies with 50× the multiplier here.
Apply `truncate_passage/1` (or a dedicated `@max_query_bytes`) to `query` too.

### SUGGESTION 7.2 — pin the reranker model revision
`config/config.exs:91` — `model: "cross-encoder/ms-marco-MiniLM-L-6-v2"` loaded
as `{:hf, model_repo()}` (`reranking/serving.ex:121-133`) with no revision. Boot
pulls whatever the HF repo HEAD is; a compromised/changed upstream silently
changes ranking behavior on a machine that then serves it. Bumblebee supports
`{:hf, repo, revision: "<sha>"}` — pin it, and pin the embedding serving the same
way if it isn't already.

---

## 8. New mix tasks — admin surface

- `Mix.Tasks.Rn.Graph.Backfill` and `Mix.Tasks.Rn.RerankEval` are `use Mix.Task`
  in `lib/mix/tasks/`. Mix is not present in a `mix release`, so neither is
  invocable in a production release — the "runs in prod unintentionally" risk is
  structurally absent. Both follow the required boot convention
  (`Mix.Task.run("app.config")` + `Application.ensure_all_started/1`), and both
  correctly use `Oban.pause_all_queues(local_only: true)`
  (`rn.graph.backfill.ex:129`, `rn.rerank_eval.ex:52`) so they cannot pause the
  long-lived node's queues.
- **SUGGESTION 8.1**: `rn.graph.backfill` clears every active git source's
  watermark and re-embeds the *entire* corpus (documented as hours of work,
  `rn.graph.backfill.ex:28-34`) with **no confirmation prompt** — a mistyped or
  shell-history-recalled invocation is a self-inflicted availability incident.
  Gate the destructive branch behind `Mix.shell().yes?/1` or a `--force` switch;
  keep `--status` prompt-free.
- **SUGGESTION 8.2** (informational): `rn.rerank_eval --queries PATH` reads an
  operator-supplied path via `Runner.load_queries!/1`. No traversal boundary
  exists for a local admin CLI — noted only so it isn't mistaken for a gap later.

---

## Priority order

1. **BLOCKER** §2 — cap `edges_query/4` with `ORDER BY weight DESC LIMIT` and cap
   the hop-2 frontier.
2. **WARNING** §3 — escape LIKE metacharacters in `suffix_name_query/2` (reuse
   `runner.ex`'s `like_pattern/1`; move it to a shared helper).
3. **WARNING** §4 — length-bound `entity` and `significant_terms/1` output.
4. **WARNING** §5 — validate staged graph rows before the LLM extractor lands.
5. **SUGGESTIONs** §1.1, §6.1, §7.1, §7.2, §8.1.

Given §2/§3/§4 are all "one unauthenticated MCP call consumes disproportionate
resources", a `statement_timeout` on the Repo pool plus a simple per-connection
request cap on the MCP endpoint would provide a useful backstop independent of
the per-call fixes.

## Tools the user should run (no Bash access here)

- `mix sobelow --exit medium` (reported clean; re-run after the §3 fragment change)
- `mix deps.audit`
- `mix hex.audit`
