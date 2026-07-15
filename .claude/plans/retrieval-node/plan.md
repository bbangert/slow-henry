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
- [x] **Verify**: ~23 Phase-4 NIF-free unit tests (guards reject oversized/binary/unsupported;
      `guarded/1` crash→`{:chunk_crashed}` & timeout→`:chunk_timeout` without killing caller;
      heuristic blank/brace boundaries + hard-cap safety valve + CRLF; breadcrumb sanitize) + 2
      tagged `:integration` real-parse tests (python/js AST chunking). credo/dialyzer/format clean.
      Post-review hardening: heuristic hard byte-cap (unbounded-chunk fix), cursor-based O(n)
      named-children, guard reorder, breadcrumb newline sanitize (see reviews/phase-4-review.md).

## Phase 5 — Secrets scrubbing `[security]` (from `design-oban.md` §1, `secrets-scrubbing.md`)

- [x] `RetrievalNode.Ingest.Scrubber` — `gitleaks_scan/1` (**temp-file, not stdin** —
      `System.cmd` has no `:stdin` option; the design's `--source -` is fictional) +
      `parse_gitleaks_report/2` (locates byte offsets via the reported Match); `regex_scan/1`
      (AWS/GCP/GitHub/Slack/JWT/PEM/connection-string patterns) for Jira/Drive text
- [x] Policy (`scrub/2`): **redact span in-place** (`[REDACTED:type]`, byte-correct +
      overlap-merged — design's codepoint `String.slice` on byte offsets was buggy) +
      `record_findings/2` writes `SecretFinding` (`match_hash` sha256 only, never raw).
      gitleaks missing/errored → **degrade to regex** (non-fatal, log + `[:retrieval_node,
      :scrub, :degraded]` telemetry); high-confidence secret surviving redaction → `{:cancel, :unredactable_secret}`
- [x] Fail-closed: `scrub/2` post-redaction re-scan; regex scanner (pure, no external
      dep) is the floor — if it raises, `{:error, :scrub_unavailable}` (nothing indexed unscanned)
- [x] **Verify**: 22 tests — planted AWS key redacted + audited (sha256, not raw; whole-row check);
      gitleaks degrade forced via `:gitleaks_cmd` config + fires telemetry; jira/drive scanned;
      PEM/dup/overlap/UTF-8 byte-offset redaction; fail-closed `redaction_left_secret?`; size cap.
      credo/dialyzer/format clean.
- [x] **Security hardening** (Phase 5 review, `reviews/phase-5-review.md`): temp file in a private
      0700 dir + `find_executable` guard (no plaintext to /tmp when gitleaks absent); secrets kept
      out of logs/telemetry; gitleaks dup-secret redaction (all occurrences); transactional audit.

## Phase 6 — Ingest pipeline `[oban]` (from `design-oban.md`) — the all-three-thin slice

> **Split into two PRs.** 6a = plumbing (Oban config, `pending_chunks` schema/context,
> `GitMirror`). 6b = Jira/Drive clients + the 4 Oban workers + cron + deletions.

- [x] **(6a)** Oban config: queues `sync: 3, chunk: 2, embed: 1, upsert: 5`; Pruner (14d),
      Lifeline (20m); `Repo` `pool_size: 20`; `:test` → `testing: :manual`. **Cron deferred
      to 6b** (added with the worker modules it references). Oban not in the tree yet (Phase 8).
- [x] **(6a)** `Retrieval.PendingChunk` schema (bigserial staging) + `Ingest.PendingChunks`
      context (insert_raw/insert_raw_all, fetch!/fetch_many!, write_chunks, set_embeddings,
      by_ids/delete_by_ids) — the staging-table access the workers use.
- [x] **(6a)** `Ingest.GitMirror` — bare `--mirror` clone/`fetch --prune`, `head_sha`,
      `changed_files` (ls-tree/diff), `show` (full content), `grep`. Arg-list `System.cmd`
      (no shell), `find_executable` guard, `Path.safe_relative` on repo slug + file path.
      Tested against a real local repo (git is always present). Reused by Phase 7 MCP tools.
- [x] **(6b)** Source clients (thin): `Ingest.Jira` (Req REST, JQL
      `resolutiondate` watermark, resolved/closed only), `Ingest.Drive` (Req +
      Changes API cursor, export Docs as `text/markdown`, handle deletions/unshares)
- [x] Workers `[oban]`:
  - [x] `RepoSync` / `JiraSync` / `DriveSync` (`:sync`) — diff vs watermark →
        `Ecto.Multi` bulk-insert `pending_chunks` (status `raw`) + one `ChunkFiles`
        job per file/issue/doc; advance watermark. `unique` on the source id;
        `{:snooze, n}` on 429 (parse `Retry-After`)
  - [x] `ChunkFiles` (`:chunk`) — **scrub → tree-sitter (guarded) → heuristic
        fallback on final attempt** (the `attempt >= max` pattern from `design-oban.md`
        §5); writes chunk rows to `pending_chunks`; enqueues one `EmbedBatch`.
        `timeout/1` 45s, `max_attempts: 5`, short custom backoff, unique on
        `pending_chunk_id`. **Fallback only on parse failures** (`:chunk_timeout` /
        `:chunk_crashed` / `:unsupported_language`) — NOT on `:too_large` /
        `:binary_content` (hard rejections → skip the file; the heuristic must not
        re-chunk oversized/binary input). Phase 4 review finding.
  - [x] `EmbedBatch` (`:embed`) — `Embedding.embed_batch/1` over the batch → write
        384-dim `embedding` back → enqueue `UpsertChunks`. `max_attempts: 3`
  - [x] `UpsertChunks` (`:upsert`) — `Ecto.Multi.insert_all` into `Retrieval.Chunk`
        with `on_conflict: {:replace, [...]}, conflict_target: [:source_id, :chunk_key]`,
        then delete consumed `pending_chunks`. Idempotent; `max_attempts: 5`
- [x] Cron (`SyncScheduler` fan-out, source ids are dynamic): git */15, jira hourly, drive */30. Cron: `RepoSync */15`, `JiraSync 0 * * * *`, `DriveSync */30` (per-source args)
- [x] Deletions: Drive unshare/removal + repo file deletion → delete matching
      `Retrieval.Chunk` rows
- [x] **Verify**: Oban `:manual` testing mode. **Full git pipeline e2e** (RepoSync real-git
      diff → ChunkFiles → EmbedBatch → UpsertChunks) lands permanent chunks; secret redacted +
      audited; re-ingest upserts not duplicates (chunk_key); deletions prune chunks; RepoSync
      watermark advances / no-op when unchanged; JiraSync via Req.Test (429 → `{:snooze}`);
      Drive/Jira parsing; SyncScheduler fan-out. 89 tests, credo/dialyzer/format clean.
- [x] **Enabling changes**: migration extending `pending_chunks` with the Chunk-building fields
      (source_id/source_type/repo/lang/chunk_key/breadcrumb/metadata/parse_status/secrets_status —
      the Phase 1 staging schema was under-specified); `Oban.Migrations` (oban_jobs table);
      test-env `Embedding.StubImpl` (deferred from Phase 3); `SyncScheduler` cron fan-out worker.

## Phase 7 — MCP tools `[mcp]` (Anubis; LAN-only, NO auth for the slice)

> From `design-mcp.md` (Anubis v1.6 registration verified against hexdocs) +
> `design-otp.md` §3. `Tools` calls only `Search`/`Ingest` — never `Repo`; all
> `System.cmd` shell-outs are confined to `Ingest.GitMirror`, never in the
> Anubis tool modules.

- [x] `RetrievalNode.MCP.Server` — `use Anubis.Server, name: "retrieval-node",
      version:, capabilities: [:tools]` with four `component` entries; added to the
      supervision tree as `{RetrievalNode.MCP.Server, transport: {:streamable_http,
      start: true}}` — `start: true` because the default gates on the Phoenix
      listener, which is off under ConnTest (server: false)
- [x] Mounted via `RetrievalNodeWeb.MCPPlug` (thin path-guarded wrapper around
      `Anubis.Server.Transport.StreamableHTTP.Plug`) placed on the Endpoint
      **before `Plug.Parsers`** — the transport reads the raw body itself and the
      Anubis plug does NOT support a `path:` option (spot-check corrected the plan).
      No bearer auth in the slice — LAN trust
- [x] Each tool = its own module (`use Anubis.Server.Component, type: :tool`) with a
      `schema do field ... end` block; `execute/2` gets ATOM-keyed validated params
      and returns `{:reply, Response.json/error(Response.tool(), ...), frame}`:
  - [x] `semantic_search(query!, source?, repo?, lang?)` → `Search.hybrid_search/2`;
        `source` maps git/jira/drive → a `source_type` filter (added to HybridQuery
        as `$8`, applied inside the shared candidates CTE); returns back-links
        (`chunk_id, source_type, repo, lang, breadcrumb, metadata, score`) — no content
  - [x] `grep(pattern!, repo?)` → `GitMirror.grep/3` (git grep); repo-less greps all
        indexed git repos; returns `{repo, path, line, text}`; invalid pattern surfaces
  - [x] `get_file(repo!, path!, ref?)` → `GitMirror.show/3`; sole full-content tool →
        `{repo, path, ref, content}`
  - [x] `list_repos()` (empty `schema do %{} end`) → `Ingest.list_repos/0` →
        `{repo, source_type, default_ref}`
- [x] Repo resolution via `Ingest.resolve_git_repo/1` / `git_repo_slugs/0` (registered
      sources, never a dir scan); `GitMirror` already argument-list-only with
      `Path.safe_relative` in `show` — traversal → `{:error, :invalid_path}`
- [x] Error contract: per-tool `format_error/1` → `Response.error(Response.tool(), msg)`
      (repo/file/ref not found, invalid pattern, path traversal) + catch-all. Spot-checked
      against `deps/anubis_mcp` source (success = `Response.json`, failure = `Response.error`)
- [x] **Verify**: 113 tests. Tool `execute/2` tested directly against real DB + real
      git mirror (list_repos, grep matches, get_file exact bytes, path-traversal
      rejected, semantic_search back-links + source_type filter + no content). Endpoint
      test drives `/mcp` through the full pipeline (transport owns `/mcp`, other paths
      pass through). Manual LAN drive with an MCP client/`Req` remains for on-device

## Phase 8 — Supervision, build & deploy `[otp]` `[deploy]` (from `design-otp.md` §1, `design-build.md`)

- [x] `RetrievalNode.Application` supervision tree (order from `design-otp.md` §1):
      `Repo → PubSub → Finch (shared Jira/Drive HTTP pool) → {Task.Supervisor,
      ChunkTaskSupervisor} → Embedding.Serving → Oban → Endpoint` (`:one_for_one`);
      Anubis rides the Endpoint acceptor pool. **No Erlang distribution / peer node
      in v1** (Option C) — ignore `design-build.md`'s RELEASE_COOKIE/peer-node steps
      — DONE: full order wired; Embedding sub-tree = `Embedding.Supervisor`
      (`:rest_for_one` over Serving + new `Warmer` GenServer), gated by
      `:embedding_serving_start` (false in test); Oban started app-wide (removed 4
      test-local `start_supervised!` Obans); Jira/Drive Req clients pass
      `finch: RetrievalNode.Finch`; explicit `{:finch, "~> 0.23"}` dep
- [x] arm64 build pipeline (`design-build.md`): self-hosted arm64 runner (NOT
      cross-built), `MIX_ENV=prod XLA_TARGET_PLATFORM=aarch64-linux-gnu mix compile`
      (compiles tree-sitter NIF on-device), grammar **prefetch** Mix task
      (`elixir,heex,eex` + `python,js,ts,go,rust,ruby,java`) into pinned
      `XDG_CACHE_HOME`, **ELF `file` verification gate** (tree-sitter `.so`, EXLA
      `.so`, `beam.smp` must all read `ARM aarch64`; hard-fail on x86), glibc ≥ 2.31
      check, `mix release` with grammar cache baked in via overlay
      — DONE: `scripts/build_arm64.sh` (uname/glibc guards, ELF gate pre+post release);
      `mix rn.grammars.prefetch` (all 10 langs, exit-nonzero if missing; ran green in
      sandbox); `mix.exs` `releases:` + `:tar` step; `rel/env.sh.eex` sets
      `RELEASE_DISTRIBUTION=none` + `XDG_CACHE_HOME→$RELEASE_ROOT/grammar-cache`
      (staged into `rel/overlays/grammar-cache` by the build script). On-arm64 run
      itself = deferred to first deploy (no arm64 hardware in this container)
- [x] systemd unit (`design-build.md`): `Type=exec`, atomic `current` symlink,
      `Restart=on-failure RestartSec=2 StartLimitBurst=10/300s` (OS-level backstop
      for C-level segfaults that bypass OTP), `EnvironmentFile=-/etc/retrieval_node/env`
      — DONE: `deploy/retrieval_node.service` (StartLimit* moved to `[Unit]` —
      design doc's `[Service]` placement was invalid, caught by systemd-analyze) +
      `scripts/deploy.sh` (unpack → `ln -sfn current` → restart → poll /healthz)
- [x] `/healthz` readiness gates: (1) grammar-cache present for allowlist,
      (2) `Nx.default_backend()` is EXLA (not silent BinaryBackend), (3) Nx.Serving
      warmed, (4) DB reachable — ready only when all pass
      — DONE: `HealthController` (200/503 + per-gate JSON); config-disabled
      subsystems report "skipped" and count as passing; `Chunking.Grammars` facade
      (NIF behind `:grammar_pack_mod` seam for tests). ALSO: `config :nx,
      default_backend: EXLA.Backend` was missing entirely — added globally
      (gate 2 would otherwise fail everywhere; this is what it guards)
- [x] **Harden `git grep` memory (deferred from Phase 7 review, Copilot #3)**: `GitMirror`
      buffers all `System.cmd` stdout before the tool caps it. `-m 100`/file + 20s timeout
      bound it, but stream via `Port`/`System.cmd(into:)` with an N-byte/N-match budget +
      early close so the cap is enforced during collection (NUL-boundary-safe parsing)
      — DONE: raw `Port` receive loop; budgets `:grep_max_bytes` 1MB /
      `:grep_max_matches` 500 (= tool-layer aggregate cap); early `Port.close` →
      `{:ok, matches, truncated?}` 3-tuple (tool layer already used that shape);
      partial trailing record dropped; timeout still outer Task.yield/brutal_kill
  - [x] **`Embedding.Serving.ready?/0` must not go stale across a serving crash/restart**
        (Copilot review, PR #2): the `:persistent_term` flag stays `true` after the
        supervised serving restarts without re-warming. Reset it to `false` when the
        serving (re)starts and re-run `warmup/0`, OR have the gate also confirm the
        serving pid is the one that warmed — decide when wiring warmup into the tree here.
        — DONE via `rest_for_one` `Embedding.Supervisor`: Serving crash restarts
        `Warmer`, whose init calls new `Serving.reset_ready/0` then re-warms in
        `handle_continue` (boot never blocked)
- [x] Postgres via apt (PGDG arm64) + pgvector; `/var/lib/retrieval_node/git-mirrors/`,
      nightly `pg_dump` snapshot to NVMe
      — DONE: `deploy/setup_postgres.sh` (PGDG, postgresql-18 + -pgvector, role/db,
      git-mirrors dir 0750) + `backup_postgres.sh` + systemd service/timer (03:15 UTC,
      N-day rotation); `runtime.exs` prod `:git_mirror_root` → env-overridable
- [x] Dev (x86-64) deltas: skip ELF gate, `mix phx.server` not release/systemd,
      default `~/.cache` grammar path
      — DONE: documented in `deploy/README.md`; build script hard-fails on x86 by
      design; dev keeps default grammar cache + `PGPORT` note
- [x] **Verify**: build on arm64 → ELF gate passes; deploy → `/healthz` green;
      x86 dev boots via `mix phx.server`
      — x86 dev boot VERIFIED: `PORT=4001 PGPORT=5433 mix phx.server` → /healthz 200
      in ~20s, all four gates ok (incl. real model warmup + grammar cache). Port 4000
      is namespace-squatted pre-rebuild (see scratchpad). Full gates green: 136 tests,
      credo --strict, format, compile -w. arm64 build+deploy legs = MANUAL on first
      on-device run (`scripts/build_arm64.sh` then `scripts/deploy.sh`)

## Phase 9 — First-slice validation & benchmark harness

- [x] Seed thin corpus: 1 git repo, a handful of resolved Jira issues, 1 Drive folder
      — DONE (git leg): `mix rn.seed` (idempotent upsert on [:source_type, :identifier];
      insert-only Oban client — overrides queues/serving off so jobs run on the real
      supervised app, not the short-lived task). Registered this repo via
      `file:///workspaces/slow-henry/.git`. Jira/Drive legs = SKIPPED until creds:
      JIRA_BASE_URL/JIRA_EMAIL/JIRA_API_TOKEN/JIRA_PROJECT_KEY, DRIVE_ACCESS_TOKEN
      (task prints exact vars). FOUND REAL BUG: binary files (favicon.ico) crash
      staging INSERT (22021, invalid UTF-8 into text col) — guard only existed
      downstream in chunking; fix in flight (skip binary pre-staging)
- [x] **Live-corpus fixes** (first REAL ingest; all invisible to the stubbed suite —
      details in scratchpad "Phase 9 session notes"): (1) binary staging guard
      `Chunking.binary_content?/1` at `insert_raw_all` (covers all 3 sync workers);
      (2) **`output_pool: :mean_pooling` missing from `Serving.child_spec`** — same
      omission exists in design-otp §2.1; unpooled {512,768} → 196608 floats →
      pgvector uint16 dim header ≡ 0 → every embed broken; fixed + loud dim guards
      in `matryoshka/1` + `warmup/0` (ready? only after a real 384-dim embed);
      (3) `UpsertChunks` `String.to_existing_atom` → `Ecto.Enum.mappings`.
      PIPELINE PROVEN: 2326 chunks @384 dims, 120/120 EmbedBatch+UpsertChunks
      completed, staging drained, live hybrid_search hits sane. Real-model
      `:integration` tests pass (2)
- [x] Benchmark harness (`embedding-model.md` protocol): 50–100 labeled queries;
      measure nDCG@10 (target ≥ 0.55), query p99 (≤ 300 ms), embed throughput
      (≥ 10 passages/s), RAM peak (≤ 1.5 GB). Test Matryoshka 384 vs 768 delta (<2%)
      — DONE: `mix rn.bench` + `Bench.Metrics`/`Bench.Runner`; 15 starter queries in
      `priv/bench/queries.jsonl` (matchers = repo/path_prefix/breadcrumb_substring,
      DB-id-free; 50–100 remains the target set). PASS/FAIL/SKIPPED table vs targets;
      graceful skips verified on unseeded corpus. 768-vs-384: corpus stores only
      vector(384) → implemented as an honest truncation-stability proxy (always
      SKIPPED vs the <2% target, needs corpus re-embed for the real delta);
      `NxServingImpl.embed_full_dims/1` bench-only seam
- [x] **Definition of done**: all 4 MCP tools answer over the thin corpus via LAN;
      one incremental-sync round proven per source; secrets scrubbing runs on the
      git path; benchmark harness exists (numbers tuned later)
      — PROVEN live (2026-07-15, evidence in session scratchpad `mcp_*.raw`):
      initialize/tools/list/tools/call over streamable HTTP (SSE + mcp-session-id);
      list_repos/grep/get_file/semantic_search all correct (search top hit =
      scrubber.ex for the secrets query; no content in hits). Incremental round on
      scratch repo: watermark 026c01a→117897d (= HEAD), new file's chunks landed,
      semantic_search finds them. Scrub live: secret_findings sha256-only, 0 raw
      keys in DB, `[REDACTED:aws_access_key_id]` in chunk content, gitleaks→regex
      degrade logged. LAN-from-another-device = the one remaining manual step.
      NOTE (recall gap, fast-follow): def-free files chunk to [] under tree-sitter
      (fail-closed, zero chunks) — consider heuristic fallback on empty results.
      Jira/Drive incremental rounds = pending real creds (Req.Test-covered in suite)
- [x] **Verify**: full `mix compile --warnings-as-errors`, `mix format --check-formatted`,
      `mix credo --strict`, `mix test`, `mix sobelow` (security)
      — ALL GREEN (2026-07-15): 175 tests + 2 real-model `:integration`, credo
      --strict 0 issues, `mix sobelow --exit` 0 findings after disposition:
      `# sobelow_skip` comments (NOT @attributes — those break -w-as-errors) on
      scrubber/git_mirror/bench false positives with rationale; `.sobelow-conf`
      ignores Config.HTTPS (LAN-only v1 by design; TLS at tunnel with the auth
      fast-follow — revisit then)

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
- **Heuristic fallback on EMPTY tree-sitter results** (recall gap found in Phase 9
  DoD): def-free files (configs, constants-only modules) chunk to `[]` under the
  leaf-def tree-walk and become invisible to search — fail-closed but lossy.
  Fall back to the heuristic chunker when `{:ok, []}`, like parse failures do.

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
