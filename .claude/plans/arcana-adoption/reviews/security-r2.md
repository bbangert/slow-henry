# Security Review R2: arcana-adoption (verification pass)

Scope: re-verify the three "fixed" priors (fan-out DoS, LIKE injection, length
bounds) and hunt new issues in post-review code. MCP LAN-only/no-auth remains
accepted pre-existing risk.

**Verdict: all three prior BLOCKER/WARNING fixes are real and close their holes.
No new BLOCKER. 1 new WARNING (poison-pill via malformed staged graph — the
`sanitize_graph/1` mitigation validates size but not shape). 3 PERSISTENT
SUGGESTIONs carried over, 3 new SUGGESTIONs.**

---

## Verification of prior fixes

### V1. LIKE escaping (prior §3) — FIXED, escaping is complete

`graph.ex:227-236`.

- `escape_like/1` (`:236`): `String.replace(text, ~r/([%_\\])/, "\\\\\\1")`. The
  Elixir literal `"\\\\\\1"` is the 4 chars `\ \ \ 1` = replacement `\\` (one
  literal backslash) + `\1` (group ref). So `%` → `\%`, `_` → `\_`, `\` → `\\`.
  All three metacharacters covered; no others exist for ILIKE. Matches
  `bench/runner.ex:162` precedent exactly.
- `fragment("? ILIKE ? ESCAPE '\\'", ...)` (`:232`) emits SQL
  `? ILIKE ? ESCAPE '\'`. With `standard_conforming_strings = on` (PG 9.1+
  default) that is a single backslash — correct. (It is also redundant:
  backslash is Postgres' default LIKE escape, so the clause is belt-and-braces.
  Harmless. Only breaks if someone sets `standard_conforming_strings = off`,
  which would be a syntax error, not a silent bypass — fail-closed.)
- Pattern is still bound (`^pattern`), so no SQL text is caller-influenced.
- `{"entity": "%"}` now ILIKEs the literal `%.\%` → 0 rows. Exploit A closed.
- Exploit B (index-unusable trigram-less pattern) is closed for the *suffix*
  tier because the pattern is now literal text.

**All three `find_entities` tiers re-checked** (`graph.ex:195-197`):
- tier 1 `exact_name_query/2` (`:225`) — `e.qualified_name == ^name`, no pattern
  matching at all. Safe.
- tier 2 — fixed as above.
- tier 3 `trigram_name_query/2` (`:238-243`) — `fragment("? %> ?", col, ^name)`
  and `word_similarity(^name, col)`. Not a LIKE context, so metacharacters have
  no meaning; `name` is bound. Safe.

**Other caller-controlled strings reaching ILIKE/trigram in the diff**: none.
`definition_snippets/2` (`graph.ex:387-406`) takes only UUIDs plus a clamped
integer limit; its one `fragment` is `"?->>'path'"` on a column, no user input.
`related_code.ex` passes `repo`/`lang` as `==` equality binds
(`graph.ex:207, 218`). `hybrid_query.ex` uses `%> ANY($9::text[])` — bound array,
not LIKE. Grepped `lib/` for `ilike|ILIKE|LIKE |fragment\(`: the only other LIKE
sites are `bench/runner.ex:150,157`, both pre-existing and both already escaped
(and `runner.ex:157`'s bare `ilike/2` is fine — backslash is PG's default LIKE
escape even without an `ESCAPE` clause).

### V2. `@max_entity_bytes 256` (prior §4) — FIXED, enforced before any query

`related_code.ex:39, 62-76`. `execute/2`'s `with` runs
`validate_entity_length/1` as the **first** clause, before `normalize_relation`
and before `run/5` — so no `Graph.find_entities/2` call (hence no trigram /
`word_similarity` work) happens for an oversized entity. Error path leaks only
the caller's own byte count and the constant cap; no schema, path, or corpus
information. Good.

`hybrid_query.ex` side also fixed: `@max_term_length 64` (`:72`) applied in
`significant_terms/1` (`:362`). Note the bound is tighter than it looks and
that's fine: the split regex `~r/[^a-z0-9_]+/` (`:360`) guarantees every surviving
term is pure ASCII `[a-z0-9_]`, so `String.length/1 <= 64` really is `<= 64
bytes`. With `@max_terms 8`, `$9` is capped at ~512 bytes. Solidly bounded.

### V3. Fan-out caps (prior §2) — FIXED for BEAM heap; residual PG-side cost

`graph.ex:160-165, 351-361, 300-314`. Both hops are bounded:

- `edges_query/4` has `order_by: [desc: e.weight], limit: @edge_fanout_limit`
  (500) — applied per traversal query, so hop 1 ≤ 500 rows even with 50 seed ids
  in the `in ^ids` array (one query, one LIMIT).
- hop 2's frontier is explicitly truncated to `@hop2_frontier_limit` (100) by
  weight desc *before* `traverse_edges/2` (`:300-304`), and that second query is
  itself capped at 500. So worst case is 2 queries × 500 rows, then
  `load_entities/1` over ≤ 1000 ids, then `Enum.take(@related_entities_limit)`.
- Crafted `relation`/`hops` combinations checked: `hops` is double-guarded
  (`related_code.ex:137`, `graph.ex:278`); `relation` comes from the literal
  `@relation_map` (`related_code.ex:28-34`). The `definitions` branch
  (`related_code.ex:96-101`) never traverses edges — it calls
  `definition_snippets/2`, whose limit is clamped to 50 (`graph.ex:388, 408`) and
  whose rows are truncated to 20 lines / 1000 chars (`graph.ex:422-437`). So the
  "50 seeds × snippets" path is 50 snippets ≈ 50 KB, not an explosion. The
  non-definitions branch feeds ≤ 50 related ids into the same clamped
  `definition_snippets/2` (`related_code.ex:108`). Bounded.

**Residual (SUGGESTION S1, below)**: the cap bounds *transferred rows and BEAM
heap*, not Postgres work. `ORDER BY weight DESC LIMIT 500` over a hot symbol with
six-figure in-degree still makes PG read every matching edge and top-N sort it.
That is a much cheaper failure mode than before (bounded memory, bounded
transfer), so this is no longer BLOCKER-class — but it is the reason a
`statement_timeout` still matters.

### V4. `sobelow_skip` claim (prior §1) — STILL ACCURATE after the restructure

Re-traced every interpolation in the rebuilt `@sql` / `@sql_graph`
(`hybrid_query.ex:278-292`):

| Site | Source | Compile-time literal? |
|---|---|---|
| `@candidate_pool` ×3 (`:149,:162,:236`) | `Application.compile_env/3` default 200 | yes (see S2) |
| `@entity_match_pool` (`:169`, used `:210`) | literal `500` | yes |
| `@mention_weight_definition/_call/_import` (`:94-96`, used `:223-225`) | literals `1.0/0.6/0.3` | yes |
| `@filters_bare` / `@filters_c` (`:127-140`) | literal strings, `$5..$8` placeholders | yes |
| `@vector_leg_sql`/`@fts_leg_sql`/`@entity_matches_sql`/`@entity_leg_sql`/`@fused_*`/`@select_sql` | composed from the above at compile time | yes |

`@stopwords` (`:82-88`) is a compile-time `MapSet` used **only** in Elixir
(`MapSet.member?/2` at `:363`) — it never reaches SQL text. Confirmed.

Runtime values, all still bind params: `$1` `Pgvector.new(embedding)`, `$2`
`text_query` (into `websearch_to_tsquery`, parameterized — MCP query text cannot
reach SQL syntax), `$3` `@rrf_k`, `$4` clamped `top_k`, `$5..$8` nil-safe filter
casts, `$9` `terms` as `::text[]`, `$10` `graph_weight` from
`Application.get_env` cast `::float`. `Repo.query!/2` (`:342`) still receives one
of exactly two compile-time strings chosen by a boolean (`:334-340`) — no
caller-influenced SQL text. The `MATERIALIZED` CTE added no new interpolation.
**Skip annotation remains justified.** A non-numeric `:graph_leg_weight` config
would fail the `$10::float` cast (error, not injection).

### V5. `rn.graph.backfill` boot overrides — NO LEAK into a long-lived node

`rn.graph.backfill.ex:105-130`. `Application.put_env/3` mutates the **calling
VM's** application environment only; there is no DB write, no `:persistent_term`
across nodes, no Oban notifier broadcast on this path. The `mix` task's VM ends
at `System.halt(0)` (`:95`), so the overrides die with it. `Oban` config override
(`queues: [], plugins: []`) is applied *before* `ensure_all_started/1`, so the
task's own Oban starts with no queues — it cannot claim the jobs it enqueues.
`Oban.pause_all_queues(local_only: true)` (`:129`) is correct and load-bearing;
without `local_only:` it would pause the dev server's queues via the shared-DB
notifier. **Verified clean.** One gap → S3 below (`mcp_server_start` is not
disabled the way the two servings are).

---

## New findings

### WARNING N1 — `sanitize_graph/1` validates size but not shape: a malformed staged graph still poison-pills the job it was added to protect

- **Location**: `lib/retrieval_node/graph.ex:450-480`, consumed at `:503-504`,
  `:544-545`, `:663`, `:672`, `:720-721`
- **Severity**: WARNING (availability + silent loss of a whole file's chunks)
- **Issue**: the sanitizer's own comment (`:441-447`) states its purpose — "junk
  symbols must never take real chunks down", drop-with-warning rather than
  raise. It only enforces `byte_size(...) <= @max_symbol_bytes`. Every
  non-string / non-map / missing-key shape either **raises inside the
  sanitizer** or **survives sanitation and raises downstream**:

  | Staged `graph` payload | Where it blows up | Exception |
  |---|---|---|
  | `{"qualified_name": null}` | `:457` `byte_size(nil)` — `Map.get/3`'s default is NOT used when the key exists with a JSON `null` | `ArgumentError` |
  | `{"qualified_name": ["a"]}` / `123` / `{}` | `:457` `byte_size/1` on non-binary | `ArgumentError` |
  | `"entities": ["foo"]` (element not an object) | `:457` `Map.get("foo", ...)` | `BadMapError` |
  | `"entities": {"a": 1}` (object, not array) | `:457` | `BadMapError`/`Protocol.UndefinedError` |
  | top-level `graph` is a JSON array or scalar | `:453` `Map.get(row.graph, ...)` | `BadMapError` |
  | entity object with no `"qualified_name"` key | passes `:457` (default `""`), then `:503` `Map.fetch!` | `KeyError` |
  | entity with no `"kind"` / non-string `kind` | `:504` `Map.fetch!` / `kind_atom/3`'s `is_binary` guard | `KeyError` / `FunctionClauseError` |
  | reference `kind` not `"call"`/`"import"` | `:557`, `:684`, `:734` | deliberate `ArgumentError` |

  So the answer to "does a malicious staged graph payload crash the consumer
  instead of being dropped?" is **yes** — `Map.get(&1, "qualified_name", "")`
  returns the raw non-string value (or `nil` for JSON `null`), and `byte_size/1`
  raises on it.
- **Exploit / blast radius**: any of these raises inside
  `UpsertChunks`' `Ecto.Multi` → the whole transaction rolls back → after
  `max_attempts` the job is discarded and **every chunk in that file is lost**
  from the index (not just the bad symbol) — precisely the outcome `:441-447`
  says it is preventing. Reachability today is low (the only producer is
  tree-sitter, `extractor/tree_sitter.ex:497-507`, which caps names at 256 bytes
  and always emits well-formed maps, and `Extractor.LLM.extract/3` is still
  `{:error, :not_configured}`, `extractor/llm.ex:20`). It becomes
  *externally influenced* the moment the LLM extractor lands: model-generated
  names from prompt-injectable Jira/Drive prose flowing into `insert_all`. This
  is the prior §5 finding **partially addressed** — the added catch-alls
  (`:557`, `:684`, `:734`) improved diagnosability (clear `ArgumentError` instead
  of `FunctionClauseError`) but kept the raise, so the poison-pill remains.
  Mark §5 **PERSISTENT (partial)**.
- **Fix sketch** — make the sanitizer a shape gate that drops, per its own
  contract:

```elixir
defp sanitize_graph(%{graph: graph} = row) when not is_map(graph), do: %{row | graph: %{}}

defp sanitize_graph(row) do
  entities  = row.graph |> Map.get("entities", []) |> List.wrap() |> Enum.filter(&valid_entity?/1)
  references = row.graph |> Map.get("references", []) |> List.wrap() |> Enum.filter(&valid_reference?/1)
  # ... existing dropped-count logging ...
end

defp valid_entity?(%{"qualified_name" => n, "kind" => k})
     when is_binary(n) and is_binary(k),
     do: byte_size(n) <= @max_symbol_bytes and n != "" and k in @entity_kinds
defp valid_entity?(_), do: false

defp valid_reference?(%{"name" => n, "kind" => k}) when is_binary(n) and k in ~w(call import),
  do: byte_size(n) <= @max_symbol_bytes and n != ""
defp valid_reference?(_), do: false
```

  With that in place the three `raise` catch-alls become genuinely unreachable
  defense-in-depth rather than the live failure mode. Also consider a cap on the
  *number* of entities/references per row (mirror the producer's
  `@max_items 10_000`, `extractor/tree_sitter.ex:42`) — the current sanitizer
  bounds each symbol's size but not the array length, and `length/1` is called
  twice per array at `:463`.

### SUGGESTION S1 — no `statement_timeout`; the caps bound BEAM heap, not Postgres CPU

- **Location**: `config/dev.exs:15`, `config/runtime.exs:36`, `config/test.exs:16`
  — grepped for `statement_timeout|parameters:`, none configured
- Three separate paths are now memory-bounded but still let one unauthenticated
  MCP call buy an arbitrarily expensive plan:
  1. `graph.ex:351-361` — `ORDER BY weight DESC LIMIT 500` over a hot symbol's
     full in-degree (V3 residual).
  2. `hybrid_query.ex:202-212` — `entity_matches` does `ORDER BY sim DESC LIMIT
     500` over everything matching `%> ANY($9)`. `@stopwords` (`:82-88`)
     *deliberately* excludes words that double as code symbols (`get`, `set`,
     `run`, `new`, `all`), so a query of 8 ubiquitous 3-char tokens is a legal
     way to force a large trigram match plus sort. Documented as a latency
     tradeoff; a timeout makes it a bounded one.
  3. `graph.ex:211-223` — `filter_repo/2`'s correlated `EXISTS` still runs
     per surviving row on the trigram tier.
- **Fix**: `parameters: [statement_timeout: "10s"]` on the Repo config (or a
  tighter per-query `SET LOCAL` on the MCP read path), plus a simple
  per-connection request cap on `/mcp`. One line, backstops the whole class.

### SUGGESTION S2 — PERSISTENT: `@candidate_pool` still interpolated without an integer assertion

`hybrid_query.ex:62`. Prior §1.1 not applied. The value is interpolated into SQL
text at `:149,:162,:236` and the `sobelow_skip` at `:311` now suppresses the
alarm, so a non-integer config value (`"5; --"`) would become SQL text with no
tooling to catch it. The compile-time guard from prior §1.1 still stands as the
fix. Same argument does not apply to `@entity_match_pool` (`:169`) or the
`@mention_weight_*` attrs (`:94-96`) — those are source literals.

### SUGGESTION S3 — `rn.graph.backfill` disables both servings but not the MCP server

`rn.graph.backfill.ex:108-109` sets `embedding_serving_start`/
`reranking_serving_start` to `false`, but `mcp_server_start?` defaults to `true`
(`application.ex:64`), so `ensure_all_started/1` (`:119`) also starts
`{RetrievalNode.MCP.Server, transport: {:streamable_http, start: true}}`
(`application.ex:32`) and `RetrievalNodeWeb.Endpoint` (`:34`) inside this
short-lived admin task. Today that opens no socket (Phoenix does not serve
unless `mix phx.server` sets `:serve_endpoints`, or `PHX_SERVER` is set in
`runtime.exs`) — so this is not a live exposure. But it is one env var away from
one: `PHX_SERVER=1 mix rn.graph.backfill` would bind the port and expose a
second unauthenticated `/mcp` listener for the task's lifetime. Add
`Application.put_env(:retrieval_node, :mcp_server_start, false)` alongside the
two serving flags — same rationale, and it also drops the transport's session
registry processes the task has no use for.

### SUGGESTION S4 — `validate_entity_length/1`'s fallback clause itself raises on a non-binary

`related_code.ex:72-76`. The guard clause is `when byte_size(entity) <= @max`;
the fallback body calls `byte_size(entity)` again for the error message, so a
non-binary `entity` (if Anubis' `:string` coercion ever admits one, or a direct
`execute/2` call in a test/tool refactor) raises `ArgumentError` instead of
returning `{:error, msg}`. Cheap: `defp validate_entity_length(entity) when
is_binary(entity)` on the happy clause and a
`defp validate_entity_length(_), do: {:error, "entity must be a string"}` tail.

---

## Persistent from R1 (unfixed, re-confirmed)

- **§5 → N1 above**: PERSISTENT (partial). Catch-alls added; poison-pill remains.
- **§1.1 → S2 above**: PERSISTENT.
- **§6.1** `definition_snippets/2` still ignores the caller's `repo`/`lang`
  filter (`graph.ex:387-406`; `related_code.ex:99,108` pass only ids), so a
  `repo`-scoped `related_code` call can return snippets from other repos reached
  via cross-repo edges. Still SUGGESTION (no authz boundary here), still makes
  the `repo` filter misleading.
- **§7.1** rerank query is still untruncated: `search.ex:102` passes raw
  `query_text` to `Reranking.rerank_scores/2`, and
  `nx_serving_impl.ex:37` pairs it with each of ~50 passages — only the passage
  side is byte-capped (`:33, :59-67`). A multi-MB `semantic_search` query is
  tokenized 50 times. PERSISTENT SUGGESTION; the fix is one `truncate_passage/1`
  call (or a `@max_query_bytes`) on `query`. Note `rerank` is caller-toggled from
  MCP (`semantic_search.ex:32-35`), so this is reachable.
- **§7.2** reranker model still unpinned: `config/config.exs:91`
  `model: "cross-encoder/ms-marco-MiniLM-L-6-v2"` with no `revision:`. Same for
  the embedding serving (`:70`). PERSISTENT SUGGESTION (supply chain).
- **§8.1** `rn.graph.backfill` still has no confirmation prompt on the
  destructive branch (`rn.graph.backfill.ex:134-157`). PERSISTENT SUGGESTION.

## Re-checked, clean

No `String.to_atom/1`, `raw/1`, `binary_to_term`, `System.cmd` with user input,
or `File.read` of a caller-supplied path anywhere in the changed set. `relation`
/ `source` / `hops` all resolve through literal maps with error branches
(`related_code.ex:28-34,126-138`; `semantic_search.ex:24,66-72`). `kind_atom/3`
(`graph.ex:807-819`) is a strict `Ecto.Enum.mappings/2` allowlist, correctly
avoiding `String.to_existing_atom/1`. Limit clamps intact
(`hybrid_query.ex:388-389` max 100, `graph.ex:203` max 50, `graph.ex:408`
max 50); `find_entities`' `:limit` is still not exposed on the MCP tool.
Scrub-before-extract ordering unchanged (`chunk_files.ex:66` chunks the
redacted content). Insert batching at 2000 respects the 65,535 bind ceiling
(`graph.ex:36, 790-799`). New migrations add no security-relevant surface.

## Priority

1. **WARNING N1** — make `sanitize_graph/1` a shape gate that drops (blocks the
   LLM extractor from landing on a poison-pill path).
2. **S1** — `statement_timeout` + `/mcp` request cap (backstops the whole
   resource-amplification class in one line).
3. **S2, S3, S4**, then persistent §6.1 / §7.1 / §7.2 / §8.1.

## Tools the user should run (no Bash access here)

- `mix sobelow --exit medium` (re-run: `graph.ex:232`'s new `fragment` and the
  restructured `hybrid_query.ex` both changed since the last clean run)
- `mix deps.audit`
- `mix hex.audit`
