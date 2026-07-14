# RetrievalNode

A self-hosted **MCP knowledge server** that makes an organization's git repos,
resolved Jira issues, and Google Drive docs searchable by an AI assistant.

It performs **hybrid semantic search** — dense vector similarity fused with
BM25/full-text ranking via Reciprocal Rank Fusion (RRF) — over content that is
incrementally ingested, chunked, and embedded. Results and file access are
exposed to clients as **MCP tools** over HTTP.

## What it does

- **Three sources, one index:** git repos (bare mirrors), resolved Jira issues,
  and exported Drive docs are chunked and embedded into a single unified store,
  so one query ranks across all of them.
- **Hybrid retrieval:** pgvector cosine similarity (HNSW) + Postgres full-text
  search (GIN), fused with RRF (k=60). Optional `source`/`repo`/`lang` filters
  are applied *before* ranking so filtered searches stay accurate.
- **Incremental ingestion:** Oban-driven pipeline (sync → chunk → embed →
  upsert) with idempotent upserts and per-source watermarks — re-runs are no-ops.
- **Local embeddings:** `nomic-embed-text-v1.5` via Bumblebee/Nx.Serving, with
  Matryoshka truncation to 384 dimensions.
- **Secrets-aware:** content is scanned (gitleaks, regex fallback) and secrets
  are redacted in-place before anything is embedded — never index a plaintext
  secret; an append-only audit log records what was found (hash only).
- **MCP tools:** `semantic_search`, `grep`, `get_file`, `list_repos`.

## Stack

Elixir/Phoenix (API-only) · Postgres + pgvector · Oban · Bumblebee/Nx/EXLA ·
tree-sitter (code chunking) · Anubis MCP.

The first vertical slice targets all three sources thin, LAN-only, no auth.
Production is self-hosted ARM (glibc); development runs on x86-64.

## Development

Requires Elixir/OTP (see `.mise.toml`) and Postgres with the `vector` extension
(**≥ 0.5.0**, for HNSW). Then:

```sh
mix setup          # deps + create/migrate the database
mix phx.server     # start the server (MCP endpoint mounts at /mcp)
mix test           # run the suite
```

> **Dev DB note:** this devcontainer ships two Postgres installs; the app uses
> the managed **PG 18 cluster on port 5433** (which has pgvector). If the DB is
> unreachable after a container restart: `sudo pg_ctlcluster 18 main start`.
> See `.claude/plans/retrieval-node/scratchpad.md` for the full story.

## Project plan

The build is sequenced in `.claude/plans/retrieval-node/plan.md` (10 phases,
Phase 0 scaffold → Phase 9 validation). Design rationale lives under
`.claude/plans/retrieval-node/research/`.
