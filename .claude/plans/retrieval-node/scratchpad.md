# Scratchpad: Retrieval Node — decisions & dead-ends

Companion to `plan.md`. Records why things are the way they are, and paths NOT taken.

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
