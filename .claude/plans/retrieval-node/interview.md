# Brainstorm: Retrieval Node — Elixir MCP knowledge server

**Status**: COMPLETE (migrated from root interview.md + scope revisited + research re-verified 2026-07-14)
**Date**: 2026-07-13 (original) · 2026-07-14 (migrated + revised)
**Coverage**: What ████ | Why ████ | Where ████ | How ████ | Edge ████ | Scope ████
**Score**: 12/12

## Summary

A single Elixir application ("retrieval node") that gives cloud Claude
(Opus/Fable via claude.ai custom connector) and Claude Code (LAN) hybrid
semantic search over three corpora: the team's git repositories, resolved Jira
issues, and Google Drive/Docs documentation. It exposes a small MCP tool
surface (Streamable HTTP) via Anubis MCP on Phoenix, ingests incrementally via
Oban workers, chunks code AST-aware via tree-sitter-language-pack (with native
`Code.string_to_quoted` enrichment for Elixir), embeds via a swappable
Nx.Serving-based embedder, and stores everything in Postgres + pgvector with
dense + BM25 hybrid retrieval fused by RRF. The design goal is one `mix
release` plus Postgres as the only services to run, with behaviours at the
two seams most likely to change (chunker, embedder).

> **Migration note (2026-07-14):** The original interview pinned the design to a
> specific single-board computer (Radxa Dragon Q6A, QCS6490, 8 GB RAM, NPU, and
> a three-board hardware allocation). Per direction, that board-specific framing
> is **out of scope for building the app** and has been removed. Resolved during
> this revision:
> - **Production target = a self-hosted ARM/aarch64 server** with a modest RAM
>   budget (design to run comfortably in a few GB). Not board-specific.
> - **The build must also compile and run on x86-64** for local dev/testing.
>   → arch-agnostic build, ARM-primary target: every native dep (EXLA, the
>   tree-sitter NIF, pgvector) must resolve on **both** aarch64 and x86-64.
> - **Data-sovereignty remains a hard v1 requirement** — index + Postgres live
>   on owned infrastructure; only query results reach the cloud model.

## Coverage Details

### What (2/2)

An MCP server exposing exactly four tools:

- `semantic_search(query, source?, repo?, lang?)` — hybrid dense+BM25 search
  with RRF fusion across code chunks, Jira issues, and Drive docs; results
  return metadata + back-links (repo/path/ref, Jira key like PROJ-1234, Drive
  file URL), with full content fetched separately to stay token-efficient
- `grep(pattern, repo?)` — ripgrep over local bare git mirrors (exact search
  is a first-class tool, not a fallback)
- `get_file(repo, path, ref?)` — exact file contents from the bare mirrors,
  so search results and fetched code always agree
- `list_repos()` — enumerate indexed sources

Plus the ingestion side: Oban-driven incremental sync for
1. git repos — `git clone --mirror` bare copies on local disk, updated by
   webhook and/or cron `git fetch`, diff-driven re-indexing of changed files only
2. Jira — resolved/closed issues only, via REST with a JQL resolution-date
   watermark (e.g. `resolutiondate >= -7d` cron); index summary + description
   + resolution notes + final comment; store issue key in payload
3. Google Drive — changes API cursor (not re-listing), export Google Docs as
   `text/markdown` (preserves headings), chunk on headings, prepend doc title
   + section path to each chunk before embedding; handle deletions/unshares
   by removing chunks

Every chunk is prepended with contextual breadcrumbs (file path + symbol name
for code; doc title + section path for docs) before embedding.

### Why (2/2)

- Cloud Claude and Claude Code need "team memory": semantic recall over code
  ("where do we debounce websocket reconnects?"), past fixes ("we hit
  something like this in PROJ-1234"), and docs ("I know we wrote this down
  somewhere") — the query shapes where JQL, Drive search, and grep all fail.
- Live connectors (Atlassian, Google Drive) already handle *current-state*
  queries; this node covers what they can't: cross-source semantic search
  over historical/settled knowledge. Division of labor: retrieval node for
  memory, connectors for state.
- Data-sovereignty: retrieval runs on owned hardware; only query results
  reach the cloud model, and index scope is the explicit data-sharing
  boundary.
- Owner explicitly prefers Elixir for this build (previous project, the Home
  Assistant MCP Server, had its stack constrained by OHF guidelines; this one
  is a free choice).

### Where (2/2)

Greenfield app — no existing codebase to scan. Proposed shape:

- One Phoenix app (no umbrella needed), single supervision tree
- Anubis MCP (`anubis_mcp` hex, ~1.5, the hermes-mcp successor) mounted as a
  Plug on the Phoenix endpoint, Streamable HTTP transport at `/mcp`
- Contexts/modules: `Ingest` (Oban workers per source: RepoSync, JiraSync,
  DriveSync → ChunkFiles → EmbedBatch → UpsertChunks), `Chunking` (behaviour
  + tree-sitter-language-pack impl + native Elixir AST impl), `Embedding`
  (behaviour + Nx.Serving impl + llama.cpp HTTP fallback impl), `Search`
  (hybrid RRF Ecto queries), `Tools` (four Anubis tool handlers)
- Storage layout: application release plus a data directory on local disk
  holding the Postgres data dir, bare repo mirrors, and periodic Postgres
  snapshots
- Deployment: `mix release` + systemd unit; Postgres via the OS package
  manager; remote iex shell for operations. **Build on an arm64 runner/box
  (glibc — Ubuntu/Debian, NOT Alpine/musl), never cross-built from x86**
  (research 2026-07-14, `research/exla-aarch64.md` + `research/treesitter-arm64.md`):
  the tree-sitter NIF has no prebuilt arm64 hex binary (compiles on-device) and
  its grammar `.so` cache is arch-specific, and EXLA/XLA artifacts are
  arch-specific too — a cross-built release segfaults on arm64. Release
  pipeline: `mix compile` (builds the Rust NIF for aarch64) → `prefetch()`
  grammars at build so no runtime download/compile → `mix release`. The x86-64
  dev path builds natively and works out of the box.

### How (2/2)

Constraints and decided approaches (versions re-verified 2026-07-14, see
`research/research-hold-check.md`):

- **Language/stack**: Elixir; Phoenix; Anubis MCP (`anubis_mcp` **v1.6.2**,
  LGPL-3.0 — the hermes-mcp successor; Streamable HTTP via Plug); Oban (cron
  plugins, unique jobs, per-queue concurrency so embedding can't starve the
  MCP endpoint); Ecto. _(Note the anubis_mcp LGPL-3.0 license: fine as a
  linked hex dependency for our own server, but recorded so it's a conscious
  choice.)_
- **Vector store**: Postgres + pgvector (`pgvector` hex **v0.4.0**, MIT), HNSW
  index. Deliberately NOT Qdrant (second service, thin Elixir clients) and NOT
  VectorChord (dual AGPL-3.0 / Elastic-License-v2; a Postgres extension that
  adds build/packaging burden — especially awkward across both aarch64 and
  x86-64 — and its ~2× QPS win only matters far beyond our
  hundreds-of-thousands-of-vectors scale). Escape hatch confirmed: VectorChord's
  vchordrq indexes build on pgvector's `vector` type, so it's an index-swap
  migration later if scale ever demands. pgvector-first stands on simplicity.
- **Hybrid search**: one SQL statement — pgvector cosine + Postgres FTS
  (tsvector) fused with reciprocal rank fusion (`row_number() OVER`, k=60) in
  a CTE. Sound, well-documented pattern (~62% → 84%+ precision vs vector-only).
- **Chunking**: `tree_sitter_language_pack` (hex **v1.12.5**, MIT; ~306 grammars
  pre-compiled, bundled `tags` queries = chunk boundaries, includes
  Elixir + HEEx + EEx grammars, on-demand parser download with local cache +
  `prefetch()`). Chunk on function/module/class nodes, cap chunk size, fall
  back to heuristic line-chunking for unparsable files. For Elixir source,
  optionally enrich via `Code.string_to_quoted/2` + Sourceror (docs/typespecs
  kept with their defs). Chunker is a behaviour. **It is a Rustler NIF with no
  documented panic-safety** (research-confirmed) — so chunk parsing runs in
  supervised isolation and parser failure is a retryable Oban failure, never a
  VM-killing incident (see Edge Cases).
- **Embedding**: **v1 model = `nomic-embed-text-v1.5`** (research 2026-07-14,
  `research/embedding-model.md`) — Apache-2.0, Bumblebee-native (HF safetensors),
  chosen for its **8192-token limit** (embeds whole Jira issues / doc sections,
  no aggressive truncation) and **Matryoshka dims** (embed at 768, store/query
  at **384** → ~½ pgvector footprint, <2% nDCG@10 loss). ~1.2 GB serving
  footprint; ~2 GB total pgvector at 500K vectors @384d. Served via Bumblebee
  (**v0.7.0**, Apache-2.0) + Nx.Serving (batching + backpressure). **Fallback:
  bge-small-en-v1.5** (67 MB, 384d) if RAM bites — but its 512-token cap forces
  harder pre-chunking. Code-specific models (jina-code) deferred: in hybrid
  dense+BM25, a general model + keyword matching usually wins; A/B later only if
  code recall underperforms. Behaviour boundary with a llama.cpp HTTP sidecar as
  the documented fallback. Embedding at query time is one short forward pass;
  bulk indexing is the only compute-heavy phase (batch/overnight acceptable).
  EXLA on aarch64 is MEDIUM-risk but well-trodden (research 2026-07-14):
  prebuilt `xla` arm64 CPU binaries exist (v0.9.1+, glibc ≥2.31), so no XLA
  source build. Warm the model with a dummy inference at startup (avoids
  10–30s first-request JIT), build on arm64, and verify the shipped `.so` is
  aarch64. **Fallback if EXLA proves flaky on the box: a llama.cpp HTTP
  embedding sidecar** (clean arm64 builds, ~1–2 day pivot) — note this one
  fallback DOES add a service, trading the "one release + Postgres" goal for
  robustness. The behaviour boundary makes it a swap, not a rewrite.
- **Security / secrets scrubbing**: filter BEFORE embedding — once embedded and
  served via MCP the data has left the network (research 2026-07-14,
  `research/secrets-scrubbing.md`). v1 approach: **gitleaks binary via
  `System.cmd`** on the bare git mirrors (MIT, ~60 rules + entropy; no
  maintained Elixir lib exists, so shelling out beats hand-rolling regexes),
  diff-driven so only changed commits are scanned (~0.5–1s/repo, matches
  incremental sync); a **small Elixir regex scanner** (seeded from gitleaks
  patterns) for the non-git sources (Jira/Drive text). **Policy = redact the
  secret span in-place (`[REDACTED:type]`) + write an audit-log row + proceed**
  — never silently index a plaintext secret; redacted chunks stay useful.
  Path/repo allowlist-denylist (credential repos + NDA material excluded
  entirely) is the first gate; content scanning is defense-in-depth behind it.
  Honest limit: encoded/base64 secrets and SaaS tokens beyond gitleaks' rule set
  will slip (TruffleHog catches more but is AGPL — rejected for v1). Quarantine +
  human-review workflow is v1.1. Bearer-token auth on the MCP endpoint; Postgres
  never exposed; the MCP server is the only reachable surface and read-only by
  design
- **Access**: Claude Code direct over LAN; claude.ai custom connector needs
  an internet-reachable URL → Cloudflare Tunnel or Tailscale Funnel (choice
  open) in front of the Phoenix endpoint
- **Ops**: Drive OAuth refresh token or service account scoped to an
  explicit shared-drive/folder allowlist (the allowlist IS the data-sharing
  boundary, keep it auditable); periodic pg_dump/snapshot to local disk,
  optionally replicated off-box for backup

### Edge Cases (2/2)

- Parser crashes: **confirmed & researched** (2026-07-14,
  `research/nif-isolation.md` + `research/nif-isolation-design.md`).
  `tree_sitter_language_pack` is a Rustler NIF; Rustler catches Rust *panics*
  but NOT C-level *segfaults*, and tree-sitter's C core has filed segfault/
  memory-corruption bugs on malformed input — any such crash kills the OS
  process hosting the BEAM, taking down `/mcp`. Containment therefore MUST be
  in a separate OS process to be *fully* contained. Three isolation shapes were
  researched; **v1 commits to option C** (in-process, guards only) as a
  pragmatic first-slice bet — the crash source is tree-sitter's C core (Rustler
  shields Rust panics, not C segfaults), so the risk is real but low against the
  team's own mostly-clean repos. **A and B are the documented escape hatch:
  adopt one the moment a real crash is observed.**
  - **C (CHOSEN, v1):** in-process parsing on a dedicated dirty scheduler +
    strict pre-flight guards + per-call `Task` timeout. Honest caveat: the
    timeout guards *hangs*, not *segfaults* — a segfault still aborts the VM
    (and `/mcp`). Risk is mitigated by guards + monitoring, not eliminated.
  - **A. Peer BEAM node pool** (`:peer`, OTP 25+) — escape hatch: reuses the
    same release (no per-arch second binary), pure OTP; crash → `{:DOWN}`/
    timeout → GenServer restart → Oban retry → heuristic fallback. Cost: enable
    Erlang distribution. _(design agent's top pick for the hardened version.)_
  - **B. External OS process** (Port / Exile + tiny tree-sitter CLI) — escape
    hatch: strongest isolation, but requires building/shipping a native binary
    for both aarch64 and x86-64 + a wire protocol.
  - **Trigger to promote C→A/B:** a segfault under C takes the node down, so add
    a supervised-restart/systemd alert + startup log marker so an unexpected VM
    abort during ingest is *visible*, not silently retried — that alert is the
    signal to harden.
  Defense-in-depth under all three: size cap → heuristic chunking for big
  files, binary/null-byte detection, language allowlist, per-call timeout,
  crash-loop circuit breaker. Parser failure is always a retryable Oban job
  failure that falls back to heuristic line-chunking, never a VM-killing
  incident
- API failures: Drive/Jira rate limits and outages → Oban retries with
  backoff; webhook storms → unique-job constraints prevent double-indexing
- Deletions: Drive changes API reports removals/unshares → delete chunks;
  repo branch deletions/force-pushes → re-diff against mirror
- Malformed/unparsable files → heuristic chunk fallback, never skip silently
- Scale: corpus expected in the hundreds of thousands of chunks (NOT
  millions) — pgvector HNSW builds in minutes, queries in single-digit ms;
  embedding throughput is the bottleneck, not the index
- Docs comments: Google Docs markdown export loses comment threads — accept;
  the live Drive connector still covers them
- Authz: single-team trust model; one bearer token per client class; no
  per-user permissions in v1

### Scope (2/2)

**In scope (v1):** the four MCP tools; three sources (git mirrors, resolved
Jira, allowlisted Drive folders); hybrid search; secrets scrubbing;
incremental sync; back-links in payloads; systemd/mix-release deploy; tunnel
+ bearer auth.

**Explicitly out of scope:**
- Open/active Jira issues and current-state queries (the Atlassian and
  Drive live connectors own those)
- Indexing all of Drive (allowlist only) and full Jira comment threads
  (final comment on resolved tickets only)
- Qdrant, VectorChord (documented escape hatch only), codesearch or any
  second retrieval service — superseded by the single-app design
- Web UI / chat interface — MCP clients are the only consumers
- Per-user permission-aware retrieval
- Reranker model, LLM-generated chunk summaries (possible v2)
- **Specific single-board-computer hardware selection and allocation** — the
  original three-board Q6A plan is deployment context, not part of building
  this app (removed 2026-07-14). The app targets a self-hosted ARM server with
  a modest RAM budget and builds/runs on x86-64 for dev/testing; the exact host
  model is a deploy-time decision.

## First Vertical Slice (v1 build phasing)

Chosen 2026-07-14: **a thin slice touching all three sources at once** (git +
Jira + Drive) on small/shallow samples, wired end-to-end (ingest → chunk →
embed → pgvector → hybrid RRF search → MCP), so source-integration surprises
(OAuth, JQL watermark, Drive changes cursor, webhook vs cron) surface early
rather than after the retrieval core is built.

- **Rationale:** the owner values de-risking the three external integrations up
  front over perfecting retrieval on one source first.
- **Tradeoff (accepted):** wider first slice — three auth/sync paths land before
  the retrieval core is fully tuned. Mitigation: keep each source's sample tiny
  (one repo, a handful of resolved Jira issues, one allowlisted Drive folder)
  and treat retrieval-quality tuning (benchmark protocol) as a fast follow, not
  a slice blocker.
- **Access (chosen):** **LAN-only, no auth — trust the LAN.** Claude Code over
  LAN is the only consumer for the slice; the tunnel + claude.ai custom
  connector are deferred to a fast-follow. **Caveat baked in: bearer-token auth
  becomes mandatory before the endpoint is ever exposed to the internet** (the
  connector leg) — "no auth" is a slice-only simplification, not the production
  posture. Postgres stays unexposed regardless.
- **Definition of done (proposed, to confirm):** all four MCP tools answer over
  the thin corpus via LAN; each source has one incremental-sync round proven;
  secrets scrubbing runs on the git path; benchmark harness exists (numbers
  tuned later).

## Codebase Context

Greenfield — no existing code. Owner context that stands in for it:

- Owner is an experienced developer; team uses Jira (not GitHub issues) and
  Google Drive/Docs for documentation
- **Deployment target (resolved 2026-07-14):** production is a self-hosted
  ARM/aarch64 server the team owns, with local NVMe/SSD storage for the
  Postgres data dir and bare repo mirrors, and a modest RAM budget (design to
  run comfortably in a few GB). **The build must also compile and run on
  x86-64** for local dev/testing — so the project is arch-agnostic to build,
  ARM-primary to deploy. Data-sovereignty is a hard requirement: index +
  Postgres stay on owned infrastructure

## Research Findings

Pre-validated during original design (sources checked 2026-07) and
**re-verified 2026-07-14** (`research/research-hold-check.md`). All five core
technology claims hold as current/production-ready:

| Component | Verified state |
|-----------|----------------|
| `anubis_mcp` | v1.6.2, LGPL-3.0; active hermes-mcp successor; Streamable HTTP via Plug; 265k+ downloads, last release 2026-06-09 |
| `tree_sitter_language_pack` | v1.12.5, MIT; 306+ grammars incl. Elixir/HEEx/EEx; **Rustler NIF, no documented panic-safety** → isolate parsing |
| `pgvector` | v0.4.0, MIT; mainstream Elixir default (971k+ downloads). VectorChord = dual AGPL/ELv2, builds on pgvector `vector` type (~2× QPS at scale) → valid escape hatch |
| `bumblebee` + `Nx.Serving` | v0.7.0, Apache-2.0; standard CPU embedding path; EXLA available; llama.cpp sidecar viable fallback |
| RRF hybrid search | Sound, battle-tested; single-query `row_number() OVER`, k=60; ~62% → 84%+ precision gain |

No deprecations found. Only material change vs the original doc: anubis_mcp is
now v1.6.2 (was ~1.5), and the tree-sitter NIF crash-risk is now confirmed
rather than assumed.


#### Approach: single Elixir app (CHOSEN)
- **Thesis**: Anubis MCP ~1.5 provides Phoenix-native MCP server; Oban maps
  1:1 onto the ingestion pipeline; pgvector collapses the vector store into
  the one database Ecto already manages; tree-sitter-language-pack removes
  the historical "no good tree-sitter story in Elixir" blocker (306 grammars,
  Hex binding, bundled tags queries, Elixir/HEEx/EEx included). Result: one
  release + Postgres, behaviours at the chunker/embedder seams
- **Antithesis**: tree-sitter-language-pack Elixir binding execution model
  unverified (NIF panic-safety); EXLA compile cost on some targets;
  anubis_mcp is post-fork ~1.x maturity

#### Approach: off-the-shelf (REJECTED, evaluated)
- Onyx: connector coverage fits (Drive/Jira/git) but Docker stack heavy
  (OpenSearch footprint) for a small self-hosted box
- OpenDocuments: right footprint (SQLite+LanceDB, MCP built in) but young,
  weak Jira story, poor code-aware chunking
- codesearch (Rust, hybrid+RRF, multi-repo MCP): excellent fit for
  mainstream languages but no Elixir grammar — superseded once the language
  pack made uniform in-app chunking viable

### Resolved during this revision

- ~~Deployment envelope~~ → **self-hosted ARM/aarch64 in production, x86-64 for
  dev/testing; arch-agnostic build, ARM-primary deploy; data-sovereignty hard.**
- ~~tree-sitter NIF vs port / panic behavior~~ → **confirmed Rustler NIF, no
  panic-safety over the C core → v1 = in-process + guards (option C), with
  peer-node/subprocess (A/B) as the documented escape hatch.**
- ~~arm64 parser artifacts~~ → **no prebuilt arm64 hex binary; grammar cache is
  arch-specific → build on an arm64 runner + `prefetch()` at build. Never
  cross-build from x86.**
- ~~EXLA aarch64 strategy~~ → **prebuilt `xla` arm64 binaries exist; warm model
  at startup, build on arm64, verify `.so` arch; llama.cpp sidecar = fallback.**
- ~~Embedding model pick~~ → **`nomic-embed-text-v1.5` @384d (Matryoshka),
  bge-small fallback; benchmark protocol in `research/embedding-model.md`.**
- ~~Secrets-scrubbing approach~~ → **gitleaks-via-`System.cmd` + Elixir regex
  for non-git; redact-in-place + audit-log + proceed.**

### Still open (deferred to planning / first slice)

1. Tunnel choice for the claude.ai leg: Cloudflare Tunnel vs Tailscale
   Funnel (bearer token on the endpoint regardless).
2. Chunk-size cap (tokens per chunk) — benchmark during the first vertical
   slice against the nDCG@10 ≥ 0.55 / p99 ≤ 300 ms targets; nomic's 8192-token
   ceiling leaves the cap a tuning knob, not a constraint.
3. Native-AST Elixir enrichment in v1, or ship uniform language-pack
   chunking first and add enrichment as v1.1?
4. musl target: only if a future deploy uses Alpine — v1 assumes glibc
   (Ubuntu/Debian arm64); neither native dep tests musl arm64.
5. Validate the first-slice benchmark protocol (test set of 50–100 labeled
   queries; nDCG@10, latency p99, throughput, RAM peak) — from
   `research/embedding-model.md`.

## Transcript

Requirements were gathered across an extended design conversation (claude.ai,
2026-07-13) covering: retrieval node architecture; Jira/Drive source strategy
vs live connectors; Elixir stack selection (Anubis MCP, Oban, Nx.Serving);
pgvector vs Qdrant vs VectorChord; build-vs-buy evaluation (Onyx,
OpenDocuments, codesearch, semcode); and chunking strategy (elixir_tree_sitter
rejected as 0.0.1-dev, tree-sitter-language-pack adopted, Code.string_to_quoted
enrichment noted). Migrated into this plan directory 2026-07-14 with the
board-specific hardware framing removed per direction; the Coverage Details
above are the synthesized contract.
