# Scratchpad: Retrieval Node — decisions & dead-ends

Companion to `plan.md`. Records why things are the way they are, and paths NOT taken.

## [2026-07-15] MERGED — PR #8 → `main` @ `2a1986c`. Plan fully shipped.

Phases 8+9 merged after a 5-agent internal review (all findings fixed) plus
three Copilot rounds (13 fixed, 1 declined). Final: 182 tests, credo/dialyzer/
format/sobelow clean. The section below records the pre-merge completion state;
the "Manual residuals" list is now the only outstanding work.

## [2026-07-15] PLAN COMPLETE — Phases 8+9 done, all 63 tasks checked

All gates green: 175 tests (+2 real-model `:integration`), credo --strict, format,
compile -w-as-errors, `mix sobelow --exit` 0 findings (dispositions in
`.sobelow-conf` + `# sobelow_skip` comments). Work is UNCOMMITTED on `main` —
Phase 8 (supervision tree, /healthz, grep streaming, build/deploy artifacts) +
Phase 9 (rn.seed, rn.bench, 3 live-corpus bug fixes, DoD proven live).

**Manual residuals** (cannot be done in this container):
1. First arm64 on-device run: `scripts/build_arm64.sh` → `scripts/deploy.sh`
   (ELF gate, grammar prefetch on arm64, systemd, /healthz on the box).
2. Jira/Drive live sync rounds: set JIRA_BASE_URL/JIRA_EMAIL/JIRA_API_TOKEN/
   JIRA_PROJECT_KEY and DRIVE_ACCESS_TOKEN, rerun `mix rn.seed`.
3. LAN drive of /mcp from another device (protocol proven locally over HTTP).
4. Benchmark numbers: `mix rn.bench` runs; grow queries.jsonl toward 50–100.

## [2026-07-14] HANDOFF → Phase 8 (fresh session)
Phases 0–7 merged to `main` (last: PR #7, MCP tools). `main` @ `7a77ca2`. All gates green
(122 tests, credo/dialyzer/format). Resume with `/phx:work .claude/plans/retrieval-node/plan.md`.

**Phase 8 = Supervision, build & deploy.** Key context beyond the plan checkboxes:
- **Supervision tree** currently has only: Telemetry, Repo, DNSCluster, PubSub,
  `{MCP.Server, transport: {:streamable_http, start: mcp_server_start?()}}`, Endpoint.
  Phase 8 must add (order per design-otp §1): Finch (shared Jira/Drive HTTP pool) →
  `{Task.Supervisor, ChunkTaskSupervisor}` → `Embedding.Serving` (Nx.Serving) → Oban.
  Oban config already exists (`config/config.exs`) but Oban is NOT started yet — cron
  won't fire until it joins the tree. `:test` keeps `testing: :manual`.
- **Deferred items to fold in** (all listed below): git-grep streaming/bounding
  (PR #7 #3), `ready?/0` reset-on-restart, ChunkTaskSupervisor + Serving in tree.
- **arm64-only, on-device build** (never cross-build): tree-sitter NIF + EXLA .so are
  arch-specific; ELF `file` verification gate must hard-fail on x86. NO Erlang
  distribution / peer node in v1 (Option C) — ignore design-build's RELEASE_COOKIE steps.
- The MCP `start:` gate (`:mcp_server_start`, default true) is the pattern to reuse for a
  future worker-only release.

## Decisions

- **One unified `chunks` table** (not per-source). RRF must rank across all sources
  in one ordered scan; per-source tables would fragment the single HNSW graph and
  force `UNION ALL` per fusion side, hurting recall. Filters (`source`/`repo`/`lang`)
  are promoted to real indexed columns; source-varying back-links live in `metadata` jsonb.
- **`pending_chunks` staging table** adopted so raw content never travels in Oban
  args (IDs only). Transient; deleted by `UpsertChunks`.
- **Embedding stored at vector(384)** everywhere (incl. staging). Matryoshka
  truncation happens in `Embedding.NxServingImpl`; nothing downstream sees 768.
- **Secrets scrubbing fused into `ChunkFiles`** (not a separate worker) — content is
  already in memory for parsing; gitleaks-missing degrades to regex (non-fatal).
- **Chunker isolation = Option C** (in-process + guards + Task timeout). Peer-node
  `:peer` isolation overruled for v1, kept as documented escape hatch.
- **`:embed` queue concurrency 1** — Nx.Serving batches internally; more Oban
  concurrency only contends with MCP request handling for CPU. Batch size comes from
  large `pending_chunk_ids` lists, not parallel jobs.
- **Build on arm64 only, never cross-build** — tree-sitter NIF has no prebuilt arm64
  hex binary (compiles on-device) and its grammar cache is arch-specific; EXLA .so is
  arch-specific too. ELF `file` gate hard-fails on any x86 artifact.
- **First slice: all three sources thin, LAN-only, NO auth.** Auth deferred but
  MANDATORY before internet exposure.

## Dead ends / rejected

- **Qdrant / VectorChord** — second service / packaging burden across arches; pgvector
  wins on simplicity at our scale. VectorChord = index-swap escape hatch only.
- **TruffleHog** for secrets — 98% accuracy via live API verification, but AGPL. Rejected
  for v1; gitleaks (MIT) chosen.
- **jina-code / code-specific embeddings** — no published code-retrieval MTEB; in hybrid
  dense+BM25 a general model + keyword usually wins. A/B later only if code recall lags.
- **bge-small as primary** — 512-token cap forces aggressive pre-chunking; nomic's 8192
  ceiling won. bge-small kept as RAM-pressure fallback.
- **Dedicated GenServer/pool for chunking** — no per-call state; `Task.Supervisor` already
  provides the supervised-async shape. A pool would add a mailbox bottleneck for zero gain.

## Open action items (carried into implementation)

- [ ] **Org-scale ingest bugs (found live on the NabuCasa pull, 2026-07-15) — filed
      as GitHub issues #9/#10/#11**: (9) staging `insert_all` blows the PG 65,535
      bind-parameter cap on repos >~5.4k files — batch it in
      `PendingChunks.insert_raw_all`; (10) submodule gitlink entries make
      `git show` fail and kill the whole RepoSync — filter mode-160000 in
      ls-tree/diff + skip-not-fail per-file; (11) empty repos (unborn HEAD) crash
      `head_sha` → should no-op sync. 4 of 71 NC sources discarded on these.

- [x] **Verify tree-sitter NIF is dirty-scheduled** — DONE, and the answer is **NO**.
      `deps/tree_sitter_language_pack/native/.../src/lib.rs`: every `#[rustler::nif]` is
      plain (no `schedule = "DirtyCpu"`); the only "schedule" hit is a code comment.
      **Consequence (as the design warned):** a slow/hung parse runs on a REGULAR BEAM
      scheduler thread and degrades whole-node scheduling fairness, not just the caller.
      The `Task.yield`+`shutdown(:brutal_kill)` timeout still bounds a *hang*, but not the
      scheduler-fairness cost of a merely-slow parse. → **Raises peer-node escape hatch
      priority** (design-otp §3.3/§3.4). Mitigation in v1: input guards (size/binary/
      allowlist) reject the worst inputs pre-NIF; monitor. Also: the dep has NO high-level
      `parse(source, lang) -> {:ok, chunks}` (design assumed one); only a low-level
      parser/cursor/node API — TreeSitterImpl builds the tree-walk chunk extraction itself.
- [ ] **Spot-check Anubis tool-failure return tuple** against `deps/anubis_mcp` source
      (docs only confirmed the success path + `Response.error/2`).
- [x] **Phase 8 hardening — stream/bound `git grep` output (PR #7 Copilot #3)** — DONE
      (Phase 8): raw `Port` receive loop in `GitMirror.grep`; budgets `:grep_max_bytes`
      1MB / `:grep_max_matches` 500; early `Port.close` → `{:ok, matches, truncated?}`;
      partial trailing record dropped; outer Task.yield timeout unchanged.
- [ ] Confirm arm64 grammar prefetch works for the full language allowlist at build time.
- [ ] Benchmark chunk-size cap + Matryoshka 384-vs-768 delta during the first slice.
- [x] **Verify Postgres `vector` extension ≥ 0.5.0** (HNSW) — DONE. Installed 0.8.5,
      and now code-backed: `EnableExtensions` migration asserts `extversion >= 0.5.0`
      and raises otherwise (runs fresh on every `mix test` DB create).
- [ ] **Verify `{:snooze, _}` does NOT increment `attempt`** in OSS Oban (used for 429
      backoff) against `deps/oban` — asserted from general knowledge, not read.
- [x] Reconcile `websearch_to_tsquery` vs `plainto_tsquery` — DONE. Picked
      `websearch_to_tsquery('english', ...)` in the raw-SQL RRF (handles quoted
      phrases / -exclude / OR safely on raw MCP-caller text). Used consistently.

## Phase 8 session notes (2026-07-14)

- **`ready?/0` staleness** fixed via `Embedding.Supervisor` (`:rest_for_one` over
  Serving + `Warmer`); `Warmer.init` resets the persistent_term then re-warms in
  `handle_continue`. Gated by `:embedding_serving_start` (false in test).
- **`config :nx, default_backend: EXLA.Backend` was missing entirely** — the
  /healthz nx_backend gate would have failed everywhere. Added globally in
  config.exs (Phase 8 healthz agent caught this).
- **Port 4000 on 127.0.0.1 is squatted by an invisible-namespace process** in the
  pre-rebuild container (same pathology as the foreign PG16 on 5432; even
  `sudo ss -ltnp` shows no owning pid). Dev boot verification uses `PORT=4001`.
  Should disappear after the devcontainer rebuild.
- systemd `StartLimitBurst/IntervalSec` belong in `[Unit]`, not `[Service]` —
  design-build.md's example was invalid; caught by `systemd-analyze verify`.

## Phase 9 session notes (2026-07-15)

- **BUG (live-corpus find #1): binary files crashed staging.** `RepoSync` staged raw
  bytes into `pending_chunks.raw_content` (text col); favicon.ico → Postgrex 22021.
  The Phase 4 binary guard sat downstream in chunking — too late. Fix: shared
  `Chunking.binary_content?/1` (NUL **or** `not String.valid?`) enforced at
  `PendingChunks.insert_raw_all` (covers all 3 sync workers); TreeSitterImpl guard
  now delegates to it. Lesson: guards must sit at the *staging* choke point, not
  only at the consumer.
- **BUG (live-corpus find #2, CRITICAL): `output_pool: :mean_pooling` was missing**
  from `Serving.child_spec` → serving emitted the full padded hidden state
  `{512, 768}` per text, matryoshka flattened it to 196,608 floats, and since
  196608 = 3×65536 the **pgvector uint16 dim header overflowed to exactly 0** →
  `vector must have at least 1 dimension` + `Pgvector.to_list` MatchError while
  logging params. EVERY EmbedBatch + query-side embed was broken; warmup/healthz
  stayed green (they never checked dims). Why tests missed it: the only tests that
  run the real model are tagged `:integration` and excluded by default — they
  assert 384 and would have caught it. Lessons: (a) fire the `:integration`
  embedding tests at least once whenever serving opts change; (b) dimension
  assertions now live in `matryoshka/1` (raise on rank-2/wrong length) and
  `warmup/0` (ready? stays false unless a real 384-dim embed succeeds).
- **The `output_pool` omission originated in the DESIGN**: `design-otp.md` §2.1's
  serving sketch has the identical bug (no `output_pool`). Faithfully implemented
  = faithfully broken. Treat design-doc serving/API sketches as unverified until
  an integration test exercises them.
- **BUG (live-corpus find #3): `UpsertChunks` used `String.to_existing_atom`** on
  staged enum strings (`"heuristic_fallback"`) — crashes under `mix run` lazy
  module loading when no loaded module has interned the atom (all 120 jobs
  discarded). Latent until embedding worked. Fix: resolve via
  `Ecto.Enum.mappings(Chunk, field)` — authoritative allowlist, forces schema
  load, never mints atoms.
- The first e2e proof of the whole ingest pipeline against a REAL repo happened
  only here in Phase 9 (Phase 6's e2e used the test stub embedder) — all three
  bugs above were invisible to the stubbed suite.
- Pipeline proven 2026-07-15: 2326 chunks @ vector_dims 384, EmbedBatch 120/120 +
  UpsertChunks 120/120 completed, pending_chunks drained to 0, hybrid_search live
  hits sane (top hits = design-ecto.md for "where is the RRF fusion query").

## ENVIRONMENT: Postgres

**FIXED in the devcontainer (effective on rebuild):** the container now installs
**PostgreSQL 18 + pgvector** itself (`.devcontainer/Dockerfile`, PGDG repo) and
runs it on the standard **port 5432** (`setup.sh` starts it + sets the password;
`postStartCommand` restarts it on later boots). App config uses `port: PGPORT ||
5432`. Superuser `postgres` / `postgres`.

- We **removed** the `ghcr.io/itsmechlark/postgresql` devcontainer feature: it
  installed **PG 16 without pgvector** and squatted 5432 in a separate namespace
  (invisible to `ps`/`pg_lsclusters`, own filesystem) — the original root cause.

### Transitional note (this pre-rebuild session ONLY)
Until the container is rebuilt, the OLD state persists: the foreign **PG 16 still
holds 5432** (no pgvector, uncontrollable from here) and **PG 18 is on 5433**
(started manually: `pg_conftool 18 main set port 5433` + `pg_ctlcluster start`).
So in THIS session run mix with `PGPORT=5433` (e.g. `PGPORT=5433 mix test`). After
a rebuild, plain 5432 works and the override is unnecessary.

Superuser access via socket (peer auth): `PGHOST=localhost` is set in the shell,
so bare `psql` goes to TCP and prompts for a password — use `PGPASSWORD=postgres
psql -h localhost -p <port>` or `sudo su postgres -c "psql -h /var/run/postgresql ..."`.

## Sudo note

Passwordless sudo works only for **root target** (`sudo apt-get`, `sudo pg_ctlcluster`).
`sudo -u postgres ...` prompts for a password (fails non-interactively). Use
`sudo su postgres -c "..."` instead (su-as-root is passwordless).

## Unresolved orchestration note

The first `planning-orchestrator` run returned a "still waiting" message instead of a
digest and wrote nothing; the design was recovered by spawning ecto/oban/otp specialists
directly. Its late children (build, mcp) landed afterward and were folded in. If
re-running: spawn design specialists directly rather than via the orchestrator.

## API Failure — 2026-07-15 00:23

Turn ended due to API error. Check progress.md for last completed task.
Resume with: /phx:work --continue
