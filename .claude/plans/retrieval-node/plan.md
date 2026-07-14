# Plan: Retrieval Node — Elixir MCP knowledge server

**Source**: `.claude/plans/retrieval-node/interview.md` (Status: COMPLETE, 12/12)
**Depth**: deep · **Generated**: 2026-07-14
**Design research**: `research/design-ecto.md`, `design-oban.md`, `design-otp.md`,
`design-build.md`, `design-mcp.md` (+ the 7 brainstorm research docs). Full code
lives there; this plan lifts the load-bearing pieces and sequences the build.

Greenfield Phoenix app: hybrid (dense + BM25/RRF) semantic search over git repos,
resolved Jira, and Google Drive docs, exposed as 4 MCP tools via Anubis MCP on
Phoenix, ingested incrementally by Oban, embedded via Bumblebee/Nx.Serving
(nomic-embed-text-v1.5 @384d), stored in Postgres + pgvector. Production =
self-hosted ARM (glibc); dev = x86-64. **First vertical slice = all three sources
thin, LAN-only, no auth.**

---

## ⚠️ Canonical reconciliation decisions (read first)

The three design agents used slightly different names. These are the canonical
choices for the plan — the design docs are correct in substance; where they differ
in naming, THIS section wins:

1. **Namespaces**: data schemas live in `RetrievalNode.Retrieval.*`
   (`Source`, `Chunk`, `SyncState`, `SecretFinding`) — from `design-ecto.md`.
   Service/context modules: `RetrievalNode.Ingest` (Oban workers + source
   clients), `RetrievalNode.Chunking`, `RetrievalNode.Embedding`,
   `RetrievalNode.Search`, `RetrievalNode.Tools` — from `design-otp.md`.
   `Ingest`/`Search` are the only contexts that touch `Repo`.
2. **Chunk natural key**: use `chunk_key` (a sha256 that already encodes
   path/symbol/chunk_index) with unique index `[:source_id, :chunk_key]` as the
   `ON CONFLICT` target (per `design-ecto.md`). Ignore the alternate
   `(source, natural_key, chunk_index)` phrasing in `design-oban.md`.
3. **Embedding dims**: store `vector(384)` everywhere, including the
   `pending_chunks` staging table (NOT 768). The Embedding impl applies
   Matryoshka truncation (embed@768 → L2-normalize first 384) and returns 384-dim
   vectors; nothing downstream ever sees 768.
4. **Staging table `pending_chunks`** (from `design-oban.md`) IS adopted — it
   keeps raw/intermediate content out of Oban args (Iron Law: args are IDs only).
   It is transient; `UpsertChunks` writes the permanent `Retrieval.Chunk` rows and
   deletes the staging rows.
5. **Secrets scrubbing** runs as an **in-process pre-step inside `ChunkFiles`**,
   not a separate Oban worker/queue. Corrected semantics (Oban agent fix):
   gitleaks **exit 1 = "secrets found" → redact + audit + PROCEED** (not cancel);
   only genuine tool breakage (missing binary / unexpected exit) degrades to the
   regex scanner; true cancel is reserved for "no scan succeeded at all."
6. **pgvector version trap**: hex `pgvector ~> 0.4` is the *Elixir client*; the
   *Postgres extension* must be **≥ 0.5.0** for HNSW — check `pg_extension.extversion`
   before the HNSW migration. Postgrex vector-type registration is mandatory or
   `<=>` silently misbehaves. Bump `maintenance_work_mem` (~1 GB) for the HNSW build.
7. **No Erlang distribution in v1**: `design-build.md` §3–4 still carry peer-node /
   RELEASE_COOKIE / distribution setup — that is **stale under Option C** (in-process
   chunking needs no distribution). Ignore those bits until/unless the peer-node
   escape hatch is adopted.

---

## Phase 0 — Scaffold & dependencies

- [x] Generate app: `mix phx.new retrieval_node --no-assets --no-html --no-mailer --binary-id`
      (API-only; MCP + JSON only, no LiveView/HTML for v1) — generated in-place with
      `--app retrieval_node --module RetrievalNode` (repo basename `slow-henry` is not a valid app name)
- [x] Add deps to `mix.exs` — all resolved on Elixir 1.20/OTP 29: anubis_mcp 1.6, oban,
      pgvector **0.4.0** client, bumblebee, nx, exla, tree_sitter_language_pack, req,
      sourceror; also added credo + sobelow (dev/test) for per-phase verification
- [x] Register the pgvector Ecto type — `lib/retrieval_node/postgrex_types.ex`
      (`Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions()`), wired via
      `config :retrieval_node, RetrievalNode.Repo, types: RetrievalNode.PostgrexTypes`;
      added `RetrievalNode.EctoTypes.TsVector` load-only type (Postgrex decodes tsvector natively)
- [x] **Verify the Postgres `vector` extension is ≥ 0.5.0** — installed extension is
      **0.8.5** (control file `default_version`); pgvector hex client is 0.4.0. HNSW supported.
- [x] `config/config.exs`: `:chunking_impl`/`:embedding_impl` swappable keys set;
      `config/test.exs` overrides `chunking_impl` → `Chunking.HeuristicImpl` (NIF-free tests)
- [x] **Verify**: `mix compile --warnings-as-errors` PASS, `mix format --check-formatted` PASS

## Phase 1 — Data layer `[ecto]` (lift verbatim from `design-ecto.md`)

- [x] Migration: `EnableExtensions` — `CREATE EXTENSION vector`, `pg_trgm`
- [x] Migration: `CreateSources` (source_type/name/identifier/policy/active/config;
      unique `[:source_type, :identifier]`)
- [x] Migration: `CreateChunks` — `tsv` GENERATED ALWAYS STORED via raw execute/2
      (literal 'english' regconfig); `embedding vector(384)`; unique [source_id, chunk_key];
      btree source_type/repo/lang/parse_status/content_hash. Verified via `\d chunks`.
- [x] Migration: `CreateChunkSearchIndexes` — `@disable_ddl_transaction true` +
      `@disable_migration_lock true`, `SET maintenance_work_mem='1GB'`, HNSW
      (m=16, ef_construction=64) + GIN on tsv, both CONCURRENTLY. Indexes confirmed present.
- [x] Migration: `CreateSyncStates` (1:1 w/ sources, `cursor` jsonb, status)
- [x] Migration: `CreateSecretFindings` (append-only audit; `match_hash` only;
      `chunk_id` on_delete: :nilify_all — confirmed FK ON DELETE SET NULL)
- [x] Migration: `CreatePendingChunks` (bigserial staging; embedding vector(384)
      per reconciliation #3, NOT 768; + scrub_mode/chunk_quality cols for Phase 6)
- [x] Schemas: `Retrieval.Source`, `Retrieval.Chunk`, `Retrieval.SyncState`,
      `Retrieval.SecretFinding` — NOTE: design's `field :tsv, ..., load_only: true`
      is invalid in Ecto 3.14; used `writable: :never, load_in_query: false` instead
- [x] **Verify**: `mix ecto.create && mix ecto.migrate` on PG18/5433 w/ pgvector 0.8.5;
      HNSW (`chunks_embedding_hnsw_idx`) + GIN (`chunks_tsv_gin_idx`) confirmed via pg_indexes

## Phase 2 — Search context `[ecto]` (the RRF query)

- [x] `RetrievalNode.Search.HybridQuery.search/1` — implemented as **raw SQL**
      (design's recommended default) via `Repo.query!/2`: shared `candidates` CTE
      applies source_id/repo/lang filters, feeds BOTH vector_search (`<=>`) and
      fts_search (`websearch_to_tsquery`/`ts_rank`) CTEs, fused `SUM(1/(60+rank))`.
      Pool 200, top_k 20. Returns back-link maps (no content). fused_score Decimal→float.
- [x] `RetrievalNode.Search.hybrid_search/2` public API — embeds via `Embedding.embed/1`
      (added minimal `RetrievalNode.Embedding` dispatcher — behaviour+impls are Phase 3),
      assembles `%{chunk, score}` back-link hits; accepts `:embedding` opt to bypass model
- [x] **Verify**: 3 tests pass — RRF ordering (both-signal match ranks top); filter
      isolation (globally-best repo-b chunk excluded under repo:"repo-a"); public API
      projects back-links without content. credo --strict clean, format clean.

## Phase 3 — Embedding subsystem `[otp]` (from `design-otp.md` §1a, §3)

- [x] `RetrievalNode.Embedding` behaviour (`embed/1`, `embed_batch/1`, `dimensions/0`)
      — @callbacks + @types added to the existing dispatcher; bare `[float()]` returns
      (per plan, not design's `embed_query`/`{:ok, _}`) to match merged Phase 2 Search
- [x] `Embedding.NxServingImpl` — `Nx.Serving.batched_run/2`; **Matryoshka
      truncation to 384 + L2 renormalize** in a pure, unit-tested `matryoshka/1`;
      `dimensions/0` → 384; `embed/1` = `embed_batch([text]) |> hd`
- [x] `Embedding.Serving` child_spec — `Bumblebee.Text.TextEmbedding.text_embedding`
      with compile/defn/output_attribute/embedding_processor opts; batch_timeout 50;
      model/params from config (`RetrievalNode.Embedding.Serving` key)
- [x] `Embedding.LlamaCppSidecarImpl` — stub only; documents the escape hatch,
      callbacks raise; config-swappable via `:embedding_impl`
- [x] `warmup/0` + `ready?/0` (persistent_term flag) implemented in `Embedding.Serving`.
      NOTE: the `Task.start/1` wiring in `Application.start` + the `/healthz` consumer
      land in **Phase 8** (supervision tree) — Serving is NOT in the tree yet, so tests
      never load the model.
- [x] **Shared-serving note** — documented in `Embedding.Serving` moduledoc (one serving
      for query+batch; second-named-serving escape hatch if p99 creeps under ingest)
- [x] **Verify**: 5 unit tests for the truncation math (768→384 len, unit L2 norm,
      leading-half selection, %{embedding:} shape) pass; 2 tagged `:integration` tests
      (load model + embed) excluded by default via `ExUnit.start(exclude: [:integration])`

## Phase 4 — Chunking subsystem `[otp]` `[security-adjacent]` (from `design-otp.md` §2-3)

- [x] `RetrievalNode.Chunking` behaviour (`chunk/2`, `allowed_languages/0`) + facade
- [x] `Chunking.TreeSitterImpl` — pre-flight guards (`@max_bytes 2M` compile_env,
      null-byte/binary detection, language allowlist) → `guarded/1` (exposed for
      NIF-free testing) using `Task.Supervisor.async_nolink(ChunkTaskSupervisor, ...)`
      + `Task.yield(@call_timeout_ms)` + `Task.shutdown(:brutal_kill)`. Returns
      `{:error, :chunk_timeout | {:chunk_crashed, _}}`. NOTE: design's fictional
      `TreeSitterLanguagePack.parse/2` doesn't exist — built the low-level
      parser/cursor tree-walk (leaf-def emission, class→methods, scoped breadcrumbs)
      over the real API. Allowlist = python/js/ts/go/rust/ruby/java (7 mainstream);
      elixir/heex/eex → heuristic until native-AST path (fast-follow, per plan)
- [x] `Chunking.HeuristicImpl` — pure line/blank-line/brace-balance chunker;
      automatic fallback + `:test`-env default. `parse_status: :heuristic_fallback`
- [x] **ACTION ITEM DONE**: tree-sitter parse NIF is **NOT dirty-scheduled**
      (all `#[rustler::nif]` plain in crate source) → slow parse degrades regular
      scheduler → raises peer-node priority. Recorded in scratchpad.
- [x] Breadcrumb builder — `RetrievalNode.Chunking.Breadcrumb.build/2` (path/title +
      symbol trail) + `prepend/2` (attach to text before embedding)
- [x] **Verify**: 31 tests pass NIF-free (guards reject oversized/binary/unsupported;
      `guarded/1` crash→`{:chunk_crashed}` & timeout→`:chunk_timeout` without killing
      caller; heuristic produces chunks, respects blank/brace boundaries) + 2 tagged
      `:integration` real-parse tests (python/js AST chunking). credo/dialyzer/format clean

## Phase 5 — Secrets scrubbing `[security]` (from `design-oban.md` §1, `secrets-scrubbing.md`)

- [ ] `RetrievalNode.Ingest.Scrubber` — `gitleaks_scan/1` (`System.cmd("gitleaks",
      ["detect","--no-git","--source","-"], ...)`, parse JSON findings) for git
      content; `regex_scan/1` (gitleaks-seeded patterns: AWS/GCP/GitHub/Slack/JWT/
      PEM/connection-strings + entropy) for Jira/Drive text
- [ ] Policy: **redact span in-place** (`[REDACTED:type]`) + write `SecretFinding`
      audit row (`match_hash` only) + proceed. gitleaks missing/errored → **degrade
      to regex scan (non-fatal), log warning**; regex-confirmed high-confidence
      secret that survives redaction → `{:cancel, ...}` (discard, don't retry forever)
- [ ] Fail-closed: content is never embedded before it has passed a scan (at least
      the regex scanner, which has no external dep and cannot legitimately fail)
- [ ] **Verify**: `mix test` — planted fake AWS key is redacted + audited; gitleaks
      absent path falls back to regex without failing; Jira/Drive text path scanned

## Phase 6 — Ingest pipeline `[oban]` (from `design-oban.md`) — the all-three-thin slice

- [ ] Oban config: queues `sync: 3, chunk: 2, embed: 1, upsert: 5`; Pruner (14d),
      Lifeline (20m), Cron; `Repo` `pool_size: 20`
- [ ] Source clients (thin): `Ingest.Git` (bare `--mirror` clone + `git fetch` +
      diff changed files vs `last_sha`), `Ingest.Jira` (Req REST, JQL
      `resolutiondate` watermark, resolved/closed only), `Ingest.Drive` (Req +
      Changes API cursor, export Docs as `text/markdown`, handle deletions/unshares)
- [ ] Workers `[oban]`:
  - [ ] `RepoSync` / `JiraSync` / `DriveSync` (`:sync`) — diff vs watermark →
        `Ecto.Multi` bulk-insert `pending_chunks` (status `raw`) + one `ChunkFiles`
        job per file/issue/doc; advance watermark. `unique` on the source id;
        `{:snooze, n}` on 429 (parse `Retry-After`)
  - [ ] `ChunkFiles` (`:chunk`) — **scrub → tree-sitter (guarded) → heuristic
        fallback on final attempt** (the `attempt >= max` pattern from `design-oban.md`
        §5); writes chunk rows to `pending_chunks`; enqueues one `EmbedBatch`.
        `timeout/1` 45s, `max_attempts: 5`, short custom backoff, unique on
        `pending_chunk_id`
  - [ ] `EmbedBatch` (`:embed`) — `Embedding.embed_batch/1` over the batch → write
        384-dim `embedding` back → enqueue `UpsertChunks`. `max_attempts: 3`
  - [ ] `UpsertChunks` (`:upsert`) — `Ecto.Multi.insert_all` into `Retrieval.Chunk`
        with `on_conflict: {:replace, [...]}, conflict_target: [:source_id, :chunk_key]`,
        then delete consumed `pending_chunks`. Idempotent; `max_attempts: 5`
- [ ] Cron: `RepoSync */15`, `JiraSync 0 * * * *`, `DriveSync */30` (per-source args)
- [ ] Deletions: Drive unshare/removal + repo file deletion → delete matching
      `Retrieval.Chunk` rows
- [ ] **Verify**: `mix test` with Oban `:manual`/`:inline` testing mode — one round
      per source produces chunks end-to-end; re-running is a no-op (content_hash);
      a parse-failing file still lands via heuristic fallback

## Phase 7 — MCP tools `[mcp]` (Anubis; LAN-only, NO auth for the slice)

> From `design-mcp.md` (Anubis v1.6 registration verified against hexdocs) +
> `design-otp.md` §3. `Tools` calls only `Search`/`Ingest` — never `Repo`; all
> `System.cmd` shell-outs are confined to `Ingest.GitMirror`, never in the
> Anubis tool modules.

- [ ] `RetrievalNode.MCP.Server` — `use Anubis.Server, name:, version:,
      capabilities: [:tools]` listing four `component` entries; add to the
      supervision tree as `{RetrievalNode.MCP.Server, transport: :streamable_http}`
- [ ] Mount on Endpoint: `plug Anubis.Server.Transport.StreamableHTTP.Plug,
      server: RetrievalNode.MCP.Server, path: "/mcp"`. **No bearer auth in the
      slice — trust the LAN** (see Risks; auth is mandatory before internet exposure)
- [ ] Each tool = its own module (`use Anubis.Server.Component, type: :tool`) with
      a `schema do field ... end` block and `execute/2` → `{:reply, Response.*, frame}`:
  - [ ] `semantic_search(query!, source?, repo?, lang?)` → `Search.hybrid_search/2`;
        returns `{source_type, back-links, breadcrumb snippet, score}` — **NOT full content**
  - [ ] `grep(pattern!, repo?)` → `GitMirror.grep/2` (`rg`); returns `{repo, path, line, text}`
  - [ ] `get_file(repo!, path!, ref?)` → `GitMirror.show/3` (`git show`); the **sole
        full-content tool** → `{repo, path, ref, content}` (so search hits & fetches agree)
  - [ ] `list_repos()` (no fields) → `Ingest.list_repos/0` → `{repo, source_type, default_ref?}`
- [ ] `Ingest.GitMirror` shell-out facade — **argument-list form only (no shell
      string interpolation)**, `System.find_executable("rg")` checked first,
      `Path.safe_relative/1` guard on `path` before every `git show`, repo slugs
      resolved via registered-repos lookup (not raw dir scan). Exceptions →
      `{:error, reason}` at this boundary so `execute/2` needs no bare rescue
- [ ] Error contract: `Response.error(Response.tool(), msg)` per-tool `format_error`
      (repo/file/ref not found, rg missing, invalid pattern, path traversal) + catch-all.
      **⚠ Spot-check** the exact Anubis tool-failure return tuple against
      `deps/anubis_mcp` source once vendored (docs confirmed success path +
      `Response.error/2` only) — see `design-mcp.md` flagged risk
- [ ] **Verify**: drive `/mcp` over LAN (MCP inspector or `Req`); all four tools
      return; `semantic_search` returns back-links, `get_file` returns exact bytes
      matching a search hit; a path-traversal `get_file` is rejected

## Phase 8 — Supervision, build & deploy `[otp]` `[deploy]` (from `design-otp.md` §1, `design-build.md`)

- [ ] `RetrievalNode.Application` supervision tree (order from `design-otp.md` §1):
      `Repo → PubSub → Finch (shared Jira/Drive HTTP pool) → {Task.Supervisor,
      ChunkTaskSupervisor} → Embedding.Serving → Oban → Endpoint` (`:one_for_one`);
      Anubis rides the Endpoint acceptor pool. **No Erlang distribution / peer node
      in v1** (Option C) — ignore `design-build.md`'s RELEASE_COOKIE/peer-node steps
- [ ] arm64 build pipeline (`design-build.md`): self-hosted arm64 runner (NOT
      cross-built), `MIX_ENV=prod XLA_TARGET_PLATFORM=aarch64-linux-gnu mix compile`
      (compiles tree-sitter NIF on-device), grammar **prefetch** Mix task
      (`elixir,heex,eex` + `python,js,ts,go,rust,ruby,java`) into pinned
      `XDG_CACHE_HOME`, **ELF `file` verification gate** (tree-sitter `.so`, EXLA
      `.so`, `beam.smp` must all read `ARM aarch64`; hard-fail on x86), glibc ≥ 2.31
      check, `mix release` with grammar cache baked in via overlay
- [ ] systemd unit (`design-build.md`): `Type=exec`, atomic `current` symlink,
      `Restart=on-failure RestartSec=2 StartLimitBurst=10/300s` (OS-level backstop
      for C-level segfaults that bypass OTP), `EnvironmentFile=-/etc/retrieval_node/env`
- [ ] `/healthz` readiness gates: (1) grammar-cache present for allowlist,
      (2) `Nx.default_backend()` is EXLA (not silent BinaryBackend), (3) Nx.Serving
      warmed, (4) DB reachable — ready only when all pass
  - [ ] **`Embedding.Serving.ready?/0` must not go stale across a serving crash/restart**
        (Copilot review, PR #2): the `:persistent_term` flag stays `true` after the
        supervised serving restarts without re-warming. Reset it to `false` when the
        serving (re)starts and re-run `warmup/0`, OR have the gate also confirm the
        serving pid is the one that warmed — decide when wiring warmup into the tree here.
- [ ] Postgres via apt (PGDG arm64) + pgvector; `/var/lib/retrieval_node/git-mirrors/`,
      nightly `pg_dump` snapshot to NVMe
- [ ] Dev (x86-64) deltas: skip ELF gate, `mix phx.server` not release/systemd,
      default `~/.cache` grammar path
- [ ] **Verify**: build on arm64 → ELF gate passes; deploy → `/healthz` green;
      x86 dev boots via `mix phx.server`

## Phase 9 — First-slice validation & benchmark harness

- [ ] Seed thin corpus: 1 git repo, a handful of resolved Jira issues, 1 Drive folder
- [ ] Benchmark harness (`embedding-model.md` protocol): 50–100 labeled queries;
      measure nDCG@10 (target ≥ 0.55), query p99 (≤ 300 ms), embed throughput
      (≥ 10 passages/s), RAM peak (≤ 1.5 GB). Test Matryoshka 384 vs 768 delta (<2%)
- [ ] **Definition of done**: all 4 MCP tools answer over the thin corpus via LAN;
      one incremental-sync round proven per source; secrets scrubbing runs on the
      git path; benchmark harness exists (numbers tuned later)
- [ ] **Verify**: full `mix compile --warnings-as-errors`, `mix format --check-formatted`,
      `mix credo --strict`, `mix test`, `mix sobelow` (security)

---

## Fast-follow (explicitly NOT in the first slice)

- Bearer-token auth + Cloudflare/Tailscale tunnel + claude.ai custom connector
  registration (REQUIRED before any internet exposure)
- git **webhook** path (cron `git fetch` covers the slice; webhook → `RepoSync`
  with unique-job dedup is the hardening)
- Native-AST Elixir enrichment (`Code.string_to_quoted` + Sourceror) — ship uniform
  language-pack chunking first
- Peer-node/`:peer` chunker isolation escape hatch (only if segfaults observed)
- Reranker / LLM chunk summaries (v2)

## Iron Law compliance check

- ✅ Oban args are IDs/strings only (raw content in `pending_chunks`, not args)
- ✅ No process without a runtime reason (chunker uses `Task.Supervisor`, not a
  bespoke GenServer/pool; embedder is `Nx.Serving`'s own process)
- ✅ Contexts own their Repo access (`Ingest`/`Search` only; `Tools` never touches `Repo`)
- ✅ Behaviours at the two changeable seams (Chunking, Embedding), config-swappable
- ✅ Idempotent upserts (`ON CONFLICT` + content_hash); unique jobs prevent storms
- ✅ Never skip a file (heuristic fallback); never silently index a secret (fail-closed)

## Risks & self-check (deep)

- **Q: What breaks first under load?** The `:embed` queue (concurrency 1, CPU-bound)
  is the throughput ceiling — by design, to protect the MCP endpoint. Bulk indexing
  is overnight-acceptable, so this is intended, not a defect. Monitor queue depth.
- **Q: What's the scariest unknown?** A tree-sitter **C-level segfault** takes the
  whole BEAM down — no OTP supervision catches it (Option C, accepted). Mitigations:
  pre-flight guards + `systemd Restart=on-failure` + a startup log marker so an
  unexpected abort during ingest is *visible*. That alert is the trigger to promote
  to the peer-node escape hatch. **Also unverified**: whether the NIF is actually
  dirty-scheduled (Phase 4 action item) — if not, slow parses degrade global scheduling.
- **Q: Where did the design docs disagree, and is the reconciliation safe?** Namespace
  (`Retrieval` vs `Ingest`), `chunk_key` vs `natural_key`, staging dims (768 vs 384).
  Reconciled at the top of this plan; all are naming/placement choices with no
  behavioral risk once fixed consistently. The one to watch: ensure the staging
  `pending_chunks.embedding` and permanent `chunks.embedding` are BOTH `vector(384)`.

## Verification commands (run after each phase)

```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix sobelow --exit          # security (auth/secret handling phases)
```
