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

- [ ] **Verify tree-sitter NIF is dirty-scheduled** (`schedule = "DirtyCpu"` in crate
      source). If NOT, slow parses block a regular scheduler → raises peer-node priority.
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

## ⚠️ ENVIRONMENT: Postgres (read before any DB work)

The devcontainer has **two** Postgres installs and the obvious one is the wrong one:

- **Port 5432** = an unmanaged **PG 16** server (from the `itsmechlark/postgresql`
  devcontainer feature) running in a separate namespace — NOT visible via `ps`,
  NOT in `pg_lsclusters`, and its SHAREDIR has **no pgvector**. `CREATE EXTENSION
  vector` fails there. Don't use it.
- **Port 5433** = the Debian-managed **PG 18** cluster (`pg_lsclusters`), which
  HAS `postgresql-18-pgvector` **0.8.5** installed and visible. This is the one
  the app uses. Started with `sudo pg_ctlcluster 18 main start` after
  `sudo pg_conftool 18 main set port 5433` + `listen_addresses localhost`.
- `setup.sh` installs pgvector keyed to the **highest** installed major (18),
  but the feature *runs* 16 — that mismatch is the root cause. Also
  `postgresql-16-pgvector` was apt-installed but the running 16 server (other
  namespace) still can't see it, so 16 is a dead end regardless.
- App config: `config/dev.exs` + `config/test.exs` use `port: PGPORT || 5433`.
- Superuser: `postgres` / `postgres` (set via `su postgres -c psql`, peer auth on
  `/var/run/postgresql` socket — `PGHOST=localhost` is set in the shell env, so
  bare `psql` goes to TCP and prompts for a password; use `-h /var/run/postgresql`
  as the postgres OS user, or `PGPASSWORD=postgres psql -h localhost -p 5433`).
- **If the cluster is down after a container restart**: `sudo pg_ctlcluster 18 main start`.

## Sudo note

Passwordless sudo works only for **root target** (`sudo apt-get`, `sudo pg_ctlcluster`).
`sudo -u postgres ...` prompts for a password (fails non-interactively). Use
`sudo su postgres -c "..."` instead (su-as-root is passwordless).

## Unresolved orchestration note

The first `planning-orchestrator` run returned a "still waiting" message instead of a
digest and wrote nothing; the design was recovered by spawning ecto/oban/otp specialists
directly. Its late children (build, mcp) landed afterward and were folded in. If
re-running: spawn design specialists directly rather than via the orchestrator.
