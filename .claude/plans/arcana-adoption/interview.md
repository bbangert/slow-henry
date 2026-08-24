# Interview: Arcana adoption for retrieval_node

**Date:** 2026-08-18
**Topic:** Can this codebase be streamlined, optimized, or gain MCP improvements
using parts of the Arcana package? (https://arcana.hexdocs.pm/readme.html)
**Status:** DECIDED 2026-08-18 — Approach B: borrow Arcana's architecture, build native (no Arcana dependency)

## Context (codebase scan)

retrieval_node is a hand-rolled RAG/retrieval MCP node:

- **Chunking:** code-aware via tree_sitter_language_pack + sourceror (`lib/retrieval_node/chunking/`)
- **Embedding:** local Bumblebee/EXLA (`lib/retrieval_node/embedding/`)
- **Store/search:** pgvector + tsvector hybrid (`lib/retrieval_node/search/hybrid_query.ex`)
- **Ingest:** Oban-based (`lib/retrieval_node/ingest/`), corpus = 81 sources
  (NabuCasa + home-assistant repos, Jira, Drive), ~300k chunks on PG 5433
- **MCP:** anubis_mcp server exposing `semantic_search`, `grep`, `get_file`, `list_repos`
- **Currently absent** (Arcana's differentiators): cross-encoder reranking,
  query rewriting, knowledge graph, grounding/NLI, answer synthesis (`ask`),
  agentic loop, LiveView dashboard

Arcana: embeddable Elixir RAG library — Chunker, Embedder (Bumblebee or API),
pgvector store, hybrid Searcher with RRF, cross-encoder Reranker (Bumblebee),
GraphRAG (LLM entity/relationship extraction at ingest, local NER + graph
traversal + RRF fusion at query time, Leiden communities), grounding via NLI,
`Arcana.Pipeline` (pluggable behaviors), `Arcana.Loop` (agentic). LLM providers
pluggable (OpenAI, Anthropic, Z.ai, custom); LLM needed at ingest only.

## What (2/2)

Evaluate and adopt Arcana components in three directions (all selected):

1. **Add missing capabilities** — reranking, query rewriting, knowledge graph, grounding
2. **Replace hand-rolled parts** — shrink maintenance surface where Arcana is equal-or-better
3. **MCP tool improvements** — richer tools (rerank-backed search, ask/synthesis, graph queries)

## Why (2/2)

- **Capability gaps:** want answer synthesis, knowledge-graph/relationship queries,
  grounded citations in the MCP surface
- **Less code to maintain:** outsourcing ingest/embed/search plumbing to a maintained
  library is a win even at equal quality
- **Informed evaluation:** no acute pain; wants honest assessment before investing

## Scope (2/2)

- **In:** all subsystems (chunking, embedding, search, ingest, MCP tools)
- **Full re-ingest of the ~300k-chunk corpus is acceptable** if components are a net win
- **Search relevance is NOT the driving pain** (explicitly not selected as motivation)

## Where (2/2)

`lib/retrieval_node/{chunking,embedding,search,ingest,retrieval,mcp}` + mix.exs deps.
Corpus DB: retrieval_node_dev on PG port 5433.

## How / Constraints (2/2)

- **LLM policy: hybrid.** Code entities/relationships extracted deterministically
  via existing tree-sitter pipeline (free, more accurate for code); LLM extraction
  (small model, e.g. Haiku/gpt-4o-mini) only for Jira/Drive prose sources.
  Query-time path must stay local (Arcana's default: local NER + graph traversal + RRF).
- Ingest-time-only LLM calls acceptable within the hybrid policy.
- Existing stack overlap is favorable: both use Ecto/Postgres/pgvector/Bumblebee/EXLA/Oban-style patterns.

## Edge cases / risks (1/2)

- LLM graph extraction over 300k chunks ≈ $20–80 one-time if done naively; hybrid
  policy avoids most of it (code chunks dominate the corpus)
- Arcana's generic chunker likely regresses tree-sitter code-aware chunking —
  replacement there needs evidence
- Re-sync behavior: incremental graph extraction on changed chunks needs checking
- Embedding model change ⇒ full re-embed; dimension changes ⇒ index rebuild

## Research synthesis (2026-08-18)

Full detail: `research/codebase-scan.md`, `research/arcana-deep-dive.md`.

**Codebase**: chunk schema deeply custom (384-dim Matryoshka-truncated nomic-embed-text-v1.5,
DB-generated tsv, unified 3-source table). Hybrid search = 216 LOC but with hard-won
per-CTE-leg filter inlining that keeps HNSW+GIN indexes live. Tree-sitter chunking extracts
names only — call/import-graph extraction is new work but scaffolding is reusable. Ingest
(~992 LOC Oban 4-stage) has a clean graph-extraction insertion point in ChunkFiles after
Chunking.chunk/2, writable into metadata jsonb. MCP tool add = 1 module + 1 line.

**Arcana** (v2.0.2, 2026-08-15): single maintainer, ~8 months old, 327 stars; 3.0.0 with
13 breaking changes already queued. GraphExtractor IS a clean 1-callback behaviour →
tree-sitter feed viable. VectorStore is a 5-callback behaviour, but whether it can target
our existing chunk table (vs Arcana's own migrations) is UNCONFIRMED — needs source read.
Reranker default ms-marco-MiniLM-L-6-v2 (prose-trained; no code evidence). Query rewriting
needs query-time LLM (conflicts with local-query-path constraint). Ingestion: text/md/pdf
only, NO git support, NO incremental re-ingest, NO Oban — so our biggest subsystem (ingest)
cannot be offloaded regardless. Entity/Relationship schema shape + grounding NLI model
unresolved (docs 404) — source-level follow-up needed to de-risk.

**Implication**: "replace hand-rolled parts" is weak — the replaceable parts (search 216
LOC, embedding 365 LOC) are small and tuned; the big part (ingest) Arcana can't replace.
"Add capabilities" (graph, rerank, grounding, MCP tools) is where the value is.

## Chosen approach (B): build native, Arcana as blueprint only

No new hex runtime deps (except possibly libgraph). Four workstreams, ~800–1,300 LOC:

1. **Cross-encoder reranker** (`lib/retrieval_node/reranking/`, ~150–250 LOC): second
   Bumblebee Nx.Serving (model chosen for code, e.g. bge/jina reranker — needs eval vs
   ms-marco-MiniLM-L-6-v2); hybrid RRF top-50 → cross-encoder → top-10. +100–300ms budget.
2. **Code knowledge graph** (~400–700 LOC): `entities`, `entity_mentions`, `relationships`
   tables. Code: extend tree-sitter traversal to extract call-sites/imports/defs
   (deterministic). Prose (jira/drive): one small-model LLM call per chunk at ingest.
   Hook: ChunkFiles stage after Chunking.chunk/2 (chunk_files.ex:65-83), incremental via
   content_hash idempotency.
3. **Graph-aware retrieval** (~100–200 LOC): query-time entity match on literal
   identifiers (no LLM/NER), 1–2 hop traversal, fused as third RRF leg in hybrid_query.ex.
   Must preserve per-CTE-leg filter inlining (index-tuning constraint).
4. **MCP tools** (~100–150 LOC): `related_code` (calls/depends-on/usages across repos);
   `semantic_search` gains rerank + graph fusion.

**Deferred/out:** Leiden community detection (simpler clustering or defer), LiveView
dashboard, grounding/NLI (later via Bumblebee NLI), `ask` synthesis (violates
local-query-path constraint).

## Open questions for research

1. Can Arcana's graph tables/fusion be fed by an external extractor (our tree-sitter
   entities) — is `GraphExtractor` a pluggable behavior?
2. Reranker: which cross-encoder model, latency at our scale, works on code?
3. How invasive is adopting Arcana's store/searcher vs keeping ours — can its
   Reranker/graph fusion run against our existing chunk schema?
4. Arcana maturity: version, maintenance, production users, upgrade cadence
5. MCP: does anything in Arcana map cleanly onto new anubis_mcp tools
   (ask, related-entities, rerank-backed search)?
6. Migration path: can old and new pipelines coexist during re-ingest?
