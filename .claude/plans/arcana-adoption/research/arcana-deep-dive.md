# Arcana Deep Dive Research

Sources: [arcana.hexdocs.pm/readme](https://arcana.hexdocs.pm/readme.html) [T1],
[GitHub repo](https://github.com/georgeguimaraes/arcana) [T1],
[hex.pm/packages/arcana](https://hex.pm/packages/arcana) [T1],
[CHANGELOG.md](https://github.com/georgeguimaraes/arcana/blob/main/CHANGELOG.md) [T1],
[Arcana module docs](https://arcana.hexdocs.pm/Arcana.html) [T1],
[Reranking guide](https://arcana.hexdocs.pm/reranking.html) [T1],
[Pipeline guide](https://arcana.hexdocs.pm/pipeline.html) [T1],
[GraphRAG guide](https://arcana.hexdocs.pm/graphrag.html) [T1],
[Arcana.VectorStore](https://arcana.hexdocs.pm/Arcana.VectorStore.html) [T1],
[Arcana.Graph.Entity](https://arcana.hexdocs.pm/Arcana.Graph.Entity.html) [T1],
[GitHub open issues](https://github.com/georgeguimaraes/arcana/issues) [T1],
[author blog post](https://georgeguimaraes.com/arcana-embeddable-rag-elixir-phoenix/) [T2],
[Elixir Forum announcement](https://elixirforum.com/t/arcana-embeddable-rag-library-for-elixir-phoenix/73820) [T3, not fetched in depth].

Gaps: could not fetch `Arcana.Reranker`, `Arcana.Graph.Relationship`/`Community`, `Arcana.Grounding` (404), migration guide, or `Arcana.Chunker`/`Arcana.Embedder` behaviour pages directly — turn budget exhausted before reaching them. Recommend a follow-up fetch pass on those specific pages before final adoption decision.

## 1. Pluggability — GraphExtractor

**Yes, it's a behaviour**, `Arcana.Graph.GraphExtractor`, with default impl `Arcana.Graph.GraphExtractor.LLM` ("extract entities + relationships in one LLM call"). [graphrag.html, T1]

Single required callback:
```elixir
@behaviour Arcana.Graph.GraphExtractor

@impl true
def extract(text, opts) do
  entities = extract_entities(text, opts)
  relationships = extract_relationships(text, entities, opts)
  {:ok, %{entities: entities, relationships: relationships}}
end
```
Configured via `config :arcana, :graph, extractor: MyApp.CustomGraphExtractor`, or you can pass an inline `fn text, opts -> {:ok, %{entities: [...], relationships: [...]}} end` directly to `GraphBuilder.build(chunks, extractor: extractor)` for rapid prototyping — no module required. [graphrag.html, T1]

This strongly suggests we **can** feed our own tree-sitter-derived entities/relationships (functions, modules, calls, imports) into Arcana's graph tables by implementing this one callback per chunk/document, bypassing LLM extraction entirely for code. The `extract/2` signature takes raw `text` though — worth confirming in source whether it also receives chunk metadata (file path, language, AST) or just a text blob, since tree-sitter extraction needs source position info, not just prose text. **Not confirmed from docs; check `lib/arcana/graph/graph_extractor.ex` source directly.**

**Ecto schemas**: `Arcana.Graph.Entity` exists (has a `changeset/2`, and is described as representing "named concepts, people, places, organizations, or other items extracted from documents for graph-based retrieval") but the doc fetch did not surface field-level detail (types, associations). A `Relationship` and likely `Community` schema almost certainly exist alongside it (community detection via Leiden is mentioned throughout) but their doc pages weren't reached. **Action item**: read `lib/arcana/graph/entity.ex`, `relationship.ex`, `community.ex` on GitHub directly for field names before designing the tree-sitter → graph mapping.

## 2. Store compatibility

Arcana ships its own migrations (installed via Igniter: `mix igniter.install arcana` then `mix ecto.migrate`) creating documents/chunks/embeddings/graph tables in **your existing Postgres/Ecto repo** — no separate database. [readme.html, GitHub, T1]

**`Arcana.VectorStore` is a behaviour** with 5 callbacks:
- `store/5` — store a vector with id + metadata in a collection
- `search/3` — semantic (vector) search
- `search_text/3` — fulltext search
- `delete/3`
- `clear/2`

Two built-in backends: `:pgvector` (default, in your Repo) and `:memory` (HNSWLib in-memory). Docs did not state whether the pgvector backend can be pointed at an **existing** chunk schema/table shape rather than Arcana's own migrated tables — this is unconfirmed and important for us since we have ~300k chunks already in a bespoke schema. Given the callback surface (store/search/delete/clear operating on "collections") it looks plausible we could implement a custom `VectorStore` backend that reads from our existing `pending_chunks`/embeddings tables instead of migrating data into Arcana's tables, but this needs source-level confirmation of what "collection" and the `store/5` id/metadata contract actually assume.

Open GitHub issues (#147, #148, #145) point at real rough edges in the migration path: `:dimensions` migration option silently defaults to 384 even though mix tasks detect it from the embedder; `create_if_not_exists` matches indexes by name only, so re-running converge can keep a stale differently-shaped index; migration version is stored in a Postgres **table comment**, which will clobber/be clobbered by host-app comments on the same table. These are all filed 2026-08-17 (very recent, by the maintainer) — signals active but not yet fully hardened migration tooling. [GitHub issues, T1]

## 3. Reranker

Conflicting info between two doc pages:
- `readme.html` states the default reranker is a local Bumblebee cross-encoder, **`cross-encoder/ms-marco-MiniLM-L-6-v2`**, running via Bumblebee/EXLA with no external call, claiming "10-25% top-k accuracy improvement" generically and a Doctor-Who-corpus eval showing +39% MRR / +62% Hit@1. [readme.html, T1]
- `pipeline.html` lists the pipeline's default reranker as `Reranker.LLM` (an LLM-based reranker), not the cross-encoder. [pipeline.html, T1]

**Conflict**: readme.html [T1] says default is local cross-encoder (ms-marco-MiniLM-L-6-v2); pipeline.html [T1] says default step is `Reranker.LLM`. Possibly the *simple* `ask/search` door defaults to the cross-encoder while the *Pipeline* `rerank()` step defaults to LLM unless configured — but this isn't stated explicitly. Needs source check (`lib/arcana/reranker.ex` + `reranker/` dir) to resolve.

`reranking.html` [T1] also mentions a ColBERT reranker option ("fast, local inference") vs LLM reranker ("slow, one API call per chunk"), and recommends skipping reranking when latency is critical. No batch-size guidance, no code-vs-prose evaluation evidence found anywhere in the fetched docs — this is a real gap for our use case (mostly source code chunks), since ms-marco-MiniLM was trained on MS MARCO web/prose passages, not code. We should not assume it transfers well to code without our own eval.

Custom reranker: implement `Arcana.Reranker` behaviour, `rerank/3` (question, chunks, opts) → `{:ok, scored_chunks}`, or pass an inline function to `Pipeline.rerank/2`. [reranking.html, T1]

## 4. Query rewriting

Implemented as a `Pipeline.rewrite()` step, backed by `Arcana.Pipeline.Rewriter` behaviour (default `Rewriter.LLM`). Its stated purpose: "cleans up conversational input into search queries." [pipeline.html, readme.html, T1] This **does require an LLM call at query time** by default (it's explicitly an LLM-backed rewriter), though presumably a custom/no-op rewriter could be substituted like other steps. Enabled by default inside `ask/2`/`search/2`. No non-LLM rewriter (e.g. rule-based) is mentioned as an alternative in the fetched docs.

## 5. Pipeline / Loop

**`Arcana.Pipeline`** — "modular RAG," composable pipeline of pluggable steps wired at code time via `|>`:
```elixir
ctx =
  Pipeline.new("Compare Elixir and Erlang...", repo: MyApp.Repo, llm: llm)
  |> Pipeline.rewrite()
  |> Pipeline.select(collections: ["elixir", "erlang"])
  |> Pipeline.decompose()
  |> Pipeline.search()
  |> Pipeline.rerank()
  |> Pipeline.answer()
  |> Pipeline.ground()
```
8 steps: gate → rewrite → expand → decompose → search → reason → rerank → ground/answer. Each step is a named behaviour with a default impl (`Rewriter`, `Searcher`, `Reranker`, etc.) — "every step that can be replaced is a behaviour with a single callback and a sensible default" per the readme. A `Pipeline.Context` struct threads through, accumulating `sub_questions`, `expanded_query`, `rerank_scores`, `context_used`, final `answer`, errors. This looks genuinely composable with foreign components — you can drop in a custom `Searcher` that queries our existing hybrid pgvector+tsvector schema instead of Arcana's own, in principle, though again the exact `Arcana.Searcher` callback contract wasn't directly fetched.

**`Arcana.Loop`** — "agentic RAG," LLM decides control flow at runtime (tool selection each iteration):
```elixir
{:ok, ctx} =
  Arcana.Loop.new("Find episodes where a Time Lord betrayed the Doctor",
    repo: MyApp.Repo, collection: "doctor-who")
  |> Arcana.Loop.run(controller_llm: "openai:gpt-4o-mini")

ctx.answer
ctx.tool_history
ctx.terminated_by  # :answered, :gave_up, :max_iterations, :error
```
Supports dual-model mode (cheap controller model picks tools; stronger model writes final answer), tool budgets, max-iteration caps, and grounding/faithfulness scoring via `Loop.ground(ctx)`. Note: `Arcana.Agent` was renamed to `Arcana.Pipeline` in v2.0.0, so any older blog posts/forum threads referencing "Agent" predate the current naming.

## 6. Maturity

- **Current version**: 2.0.2 (released 2026-08-15). Package has 17 published versions from 0.0.1 up. First "1.0.0" release was 2025-12-30 — so it's ~8 months old as a stable-numbered project, with 2.0.0 landing 2026-04-24 (major rename/restructure) and a **3.0.0 already in the Unreleased changelog** describing a "significant overhaul driven by multi-tenant production feedback" (collection scoping/strict mode, unified `SearchResult` struct, optional `bumblebee`/`req_llm` deps, optional dashboard, file-parser registry, 13 documented breaking changes). This is a project still moving fast and breaking things. [hex.pm, CHANGELOG, T1]
- **Downloads**: 23,245 all-time, 931/30-days — modest adoption. One dependent package on hex.pm.
- **GitHub**: 327 stars, 12 forks, 5 open issues, 6 open PRs, 476 commits on main. Sole maintainer appears to be `georgeguimaraes` (also the author of the intro blog post). No visible evidence of other core contributors or a company backing it, and no explicit "used in production by X" claims found in fetched pages — the phrase "driven by multi-tenant production feedback" in the 3.0.0 changelog is the only hint someone is running it at real scale, but it's not attributed to a named company.
- **License**: Apache-2.0.
- **Open issues (all filed 2026-08-17 by the maintainer)** point to real, current sharp edges: migration `:dimensions` mismatch defaults, index-shape drift on `converge`, migration version stored in a table comment (collision risk with host app), TaskSupervisor deprecation shim gaps, `SearchResult` serialization not being deriveable by host apps. These read like a maintainer actively hardening the library from dogfooding, which is a good sign for responsiveness but confirms the library is not yet fully baked for multi-tenant/production edge cases. [GitHub issues, T1]
- **Elixir/Phoenix version requirements**: not stated in any fetched doc page. Needs a direct check of `mix.exs` on GitHub.
- **pgvector/HNSW**: default backend is pgvector-backed Postgres tables; separately offers an in-memory HNSWLib backend as an alternative (not a performance layer on top of pgvector — a distinct backend choice, e.g. for tests or ephemeral use). Roadmap lists additional planned backends (TurboPuffer, ChromaDB). Nothing found about Arcana managing HNSW *index* creation/tuning parameters (lists, ef_search, etc.) within the pgvector backend — likely lives in the migration/converge code that issues #147/#148 are about.

## 7. Ingestion

File types found explicitly mentioned: **text, Markdown, PDF** (`ingest/2` for raw text, `ingest_file/2` for files). Chunking defaults to "overlapping token-based windows (450 tokens, 50 overlap)" with an optional semantic-chunking alternative, and chunker is pluggable via behaviour (`Arcana.Chunker`, not directly fetched). The 3.0.0 unreleased changelog adds a "file parser registry with custom extension routing" and "enhanced chunking with byte offsets and page ranges for PDFs" — i.e. custom file-type/parser plugins are becoming a first-class 3.0 feature, which matters for us if we want a tree-sitter-aware chunker/parser registered for source files.

**Incremental re-ingest**: not addressed in any fetched page — no documented diffing/upsert story for re-ingesting a changed file. Given we ingest ~300k chunks from a live git-tracked corpus with frequent changes, this is a meaningful open question to verify against source (`Arcana.Ingest`, `delete/2` exists for removing a document's chunks wholesale, suggesting the current pattern may be delete-and-reingest rather than incremental diff).

**Oban**: **Not shipped.** Roadmap explicitly lists "Async ingestion via Oban" as planned/incomplete. [readme.html, T1] Given we already use Oban-style patterns for our ingest pipeline, this is a gap we'd have to bridge ourselves (wrapping `Arcana.ingest/2` in our own Oban worker, which is straightforward but not provided out of the box).

## 8. Grounding/NLI

CHANGELOG confirms **v1.6.0 (2026-03-04)** added "graph-assisted search and hallucination detection via **Hallmark NLI**." [CHANGELOG, T1] Direct doc page `Arcana.Grounding` 404'd during this research pass, so the exact model backing "Hallmark NLI," how it's invoked (`Pipeline.ground()` / `Loop.ground(ctx)` are the exposed entry points per the Pipeline docs), and its performance characteristics are **unconfirmed** — flag as a follow-up fetch (`arcana.hexdocs.pm/grounding.html` guide page, or GitHub source `lib/arcana/grounding/`).

## Synthesis

Arcana is a young (~8 months), single-maintainer, fast-moving (already on its second major-version rewrite, with a third planned) but reasonably well-designed Elixir RAG library: nearly every extension point (chunker, embedder, reranker, rewriter, searcher, vector store, graph extractor) is a small behaviour with one callback and a documented default, which matches our goal of reusing our own tree-sitter extraction and existing hybrid-search schema rather than adopting Arcana's storage wholesale. The clearest fit is `Arcana.Graph.GraphExtractor` for feeding our own code-derived entities/relationships into its graph tables, and potentially a custom `Arcana.VectorStore`/`Arcana.Searcher` implementation over our existing chunk schema — but neither is confirmed to work against a schema shape other than Arcana's own migrations without deeper source reading. Real gaps for our use case: no evidence the default cross-encoder reranker (trained on MS MARCO prose) performs well on code; no Oban integration; no incremental re-ingest story; and active open issues around pgvector migration correctness (index drift, dimension defaults, comment-based versioning) that would need resolving or working around before trusting it with ~300k chunks. Recommend a second research pass reading `lib/arcana/graph/*.ex`, `lib/arcana/vector_store*.ex`, `lib/arcana/searcher*.ex`, and `mix.exs` directly from GitHub source (not just doc pages) before making an adoption decision, since several load-bearing details (Entity/Relationship schema fields, VectorStore's assumptions about "collections," minimum Elixir/OTP version) were not resolvable from hexdocs guide pages alone.
