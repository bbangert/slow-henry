# Deployment Validation: retrieval_node (Phase 8 — arm64 self-hosted)

## Summary
Solid, well-commented build/deploy pipeline. Two real BLOCKERS: migrations
have no working invocation path in prod, and `ExecStop` cannot function with
`RELEASE_DISTRIBUTION=none`. Backup script's default path will fail
permission checks on first run. Several WARNINGs around endpoint URL
scheme/443 mismatch and missing explicit `TimeoutStopSec`.

## Blockers (Must Fix)

### Migrations have no working runtime entrypoint
- **Location**: `deploy/README.md:21`, `deploy/setup_postgres.sh:80-81`, `mix.exs` (releases), `scripts/deploy.sh`
- **Problem**: README/setup script both instruct `bin/retrieval_node eval "RetrievalNode.Release.migrate()"`, but no `RetrievalNode.Release` module exists anywhere in `lib/` (confirmed via search). That call will raise `UndefinedFunctionError`. Additionally, `scripts/deploy.sh` never runs migrations at all — it unpacks, symlinks, restarts, and polls `/healthz`, which only does `SELECT 1` (passes on an empty/un-migrated DB). A first deploy will boot "healthy" with no schema and no `vector` extension.
- **Fix**: Add `lib/retrieval_node/release.ex` with the standard `migrate/0` (Ecto.Migrator.with_repo) implementation, and either (a) wire it as a `release_command`-equivalent step invoked explicitly by `deploy.sh` before `systemctl restart`, or (b) document it as a required manual pre-restart step and have `deploy.sh` fail loudly if it's skipped. Also add `ecto_sql`/migrator to the release's included applications if using `mix release` defaults (should already be pulled in transitively, but verify `mix release` output includes `:ecto_sql`).

### `ExecStop` requires distribution, but `RELEASE_DISTRIBUTION=none` disables it
- **Location**: `deploy/retrieval_node.service:22`, `rel/env.sh.eex:10`
- **Problem**: The generated `bin/retrieval_node stop` command works by RPC-connecting to the running node over Erlang distribution. With `RELEASE_DISTRIBUTION=none` (deliberate per the design doc), that connection is impossible, so `ExecStop` will fail every single `systemctl stop`/`restart`. Systemd then falls back to sending SIGTERM directly (which the BEAM's foreground `start` mode does handle for graceful app shutdown), so this is likely non-fatal in practice, but it means every restart logs a failed `ExecStop`, wastes part of the stop timeout waiting on a command that can never succeed, and gives false signal in `systemctl status`/journals during incident response.
- **Fix**: Remove `ExecStop=` entirely (let systemd's default SIGTERM/SIGKILL sequence handle it, which is what actually happens today) and set `TimeoutStopSec` explicitly (see Warnings) so the intended ≥60s drain window is guaranteed rather than incidental.

## Warnings

### Endpoint URL scheme/port (443/https) doesn't match how the app actually serves
- **Location**: `config/runtime.exs:66-75`
- **Problem**: `url: [host: host, port: 443, scheme: "https"]` is phx.new boilerplate left in place, but the `http:` listener binds `PORT` (default 4000) with no `https:` config and no `force_ssl` — consistent with the LAN-only, TLS-absent-by-design posture, but the mismatched `url:` will make Phoenix generate `https://host:443/...` links/asset URLs that don't correspond to reality if anything ever calls `url()`/`Routes`/static helpers.
- **Fix**: Either set `url: [host: host, port: port, scheme: "http"]` to match reality, or add a comment explaining this is intentionally decorative (unused by MCP clients hitting the port directly) so a future reader doesn't "fix" it into an actually-broken SSL config.

### No explicit `TimeoutStopSec` — Iron Law 2 (≥60s graceful shutdown) is only accidental
- **Location**: `deploy/retrieval_node.service`
- **Problem**: Relying on systemd's default (90s on most distros, but not guaranteed/pinned) rather than an explicit value.
- **Fix**: Add `TimeoutStopSec=60` (or higher) explicitly in `[Service]`.

### Backup default `BACKUP_DIR=/var/backups/retrieval_node` will fail on a fresh host
- **Location**: `deploy/backup_postgres.sh:16,21`, `deploy/setup_postgres.sh` (no dir creation)
- **Problem**: The backup service runs as `User=postgres` (non-root). `mkdir -p /var/backups/retrieval_node` requires write access to `/var/backups`, which on stock Debian/Ubuntu is `root:root 0755` — the `postgres` user cannot create a subdirectory there. Neither `setup_postgres.sh` nor the service pre-creates/chowns this path, so the first timer run fails with `set -e` exiting non-zero (silently, until someone checks `journalctl -u retrieval_node-backup`).
- **Fix**: Have `setup_postgres.sh` create and chown the default `BACKUP_DIR` (`install -d -o postgres -m 0750 /var/backups/retrieval_node`), or default `BACKUP_DIR` to somewhere under `/var/lib/postgresql` that's already postgres-owned.

### `PROTECT_SYSTEM`/`git_mirror_root` path not covered by any migration/setup consistency check
- **Location**: `config/runtime.exs:64`, `deploy/setup_postgres.sh:28,86-87`
- Consistent (both default `/var/lib/retrieval_node/git-mirrors`), no action needed — noted only because it was in-scope; no bug found.

## Configuration Review

### Runtime Configuration — ✅
Secrets (`DATABASE_URL`, `SECRET_KEY_BASE`) raise if missing; `PHX_SERVER`-gated `server: true` correctly documented in `deploy/README.md` env file. Pool size configurable (`POOL_SIZE`, default 20 — reasonable for solo/LAN workload). No DB SSL config (`ssl:` commented out) — acceptable for a Postgres-on-localhost LAN-only deployment per WHY-CONTEXT, but flag if `DATABASE_URL` ever points off-box.

### Health Checks — ✅
`/healthz` (`lib/retrieval_node_web/controllers/health_controller.ex`) is a genuine readiness check (DB round-trip, grammar cache presence, EXLA backend, embedding warmup), correctly gates on subsystem config rather than hardcoding. `deploy.sh`'s poll target (`PORT` env, default 4000) matches `runtime.exs`'s default — no drift. No separate startup/liveness endpoints, but a single well-designed readiness probe plus systemd's own process-alive semantics is reasonable for this topology (no k8s here).

### Container/Systemd Configuration — ⚠️
Non-root user: yes (`User=retrieval_node`, created via `useradd --system` in setup script). No CPU limits present (correct — Iron Law 5 honored, none set). Hardening (`NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=true`) correctly leaves `/opt` writable for EXLA/.so `dlopen`+exec and doesn't collide with `ReadWritePaths=/var/lib/retrieval_node`. See Blockers/Warnings above for `ExecStop` and `TimeoutStopSec`.

### Database — ⚠️
PGDG apt repo + `postgresql-18-pgvector` package approach is correct for arm64 Debian/Ubuntu. Idempotent (checks for existing repo file/role/db before acting). `vector` extension deliberately deferred to Ecto migrations (good separation) but see the migration-invocation blocker above — this dependency chain is currently broken end-to-end.

### Observability — not deeply in scope for this diff (no Sentry/AppSignal, no JSON logging changes visible); out of scope for Phase 8 build/deploy artifacts per the task description.

## Pre-Deploy Checklist
- [ ] Add `RetrievalNode.Release.migrate/0` and wire it into the deploy flow (or document+enforce as a required manual step) — BLOCKER
- [ ] Remove/replace `ExecStop` given `RELEASE_DISTRIBUTION=none` — BLOCKER
- [ ] Fix `BACKUP_DIR` default permissions — WARNING
- [ ] Add explicit `TimeoutStopSec=60` — WARNING
- [ ] Reconcile `url: [scheme: "https", port: 443]` vs actual plain-HTTP LAN serving — WARNING
- [ ] Rollback procedure: documented informally in `deploy.sh`'s failure message (repoint `current` symlink) — acceptable but manual
