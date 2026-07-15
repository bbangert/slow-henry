# retrieval_node: production deploy (self-hosted arm64)

Production target is a self-hosted **aarch64 (ARM64), glibc** Linux host.
There is no Erlang distribution / peer nodes in v1 — the release runs as a
single BEAM node (`RELEASE_DISTRIBUTION=none`, see `rel/env.sh.eex`). Never
cross-build: the tree-sitter NIF and EXLA's `.so` are architecture-specific
and must be compiled on the box that will run them.

## One-time host setup

```
sudo RETRIEVAL_NODE_DB_PASSWORD='...' deploy/setup_postgres.sh
```

This adds the PGDG apt repo, installs `postgresql-18` + the `pgvector`
package, creates the `retrieval_node` system user, the app database/role,
`/var/lib/retrieval_node/git-mirrors` (owned by that user), and installs the
nightly backup script to `/usr/local/bin/retrieval_node-backup.sh`.

`CREATE EXTENSION vector` is **not** run by this script — it's applied by
Ecto migrations (`bin/retrieval_node eval "RetrievalNode.Release.migrate()"`
or `mix ecto.migrate` in dev), so the extension's presence stays in sync with
migration history instead of drifting from an out-of-band step.

Copy the unit files in and enable them:

```
sudo cp deploy/retrieval_node.service /etc/systemd/system/
sudo cp deploy/retrieval_node-backup.service deploy/retrieval_node-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now retrieval_node-backup.timer
# retrieval_node.service itself is started by scripts/deploy.sh's first run
```

### Production env file — `/etc/retrieval_node/env`

Root-owned, `0600`, referenced by `retrieval_node.service` via
`EnvironmentFile=-/etc/retrieval_node/env` (kept out of the unit file, which
is world-readable via `systemctl cat`):

```
DATABASE_URL=ecto://retrieval_node:PASSWORD@localhost:5432/retrieval_node_prod
SECRET_KEY_BASE=<mix phx.gen.secret output>
PHX_HOST=retrieval.internal.example.com
PORT=4000
PHX_SERVER=true
# Only needed to override the grammar cache baked into the release
# (rel/env.sh.eex defaults to $RELEASE_ROOT/grammar-cache):
# XDG_CACHE_HOME=/some/persistent/path
# Only needed if git mirrors live somewhere other than the default:
# GIT_MIRROR_ROOT=/var/lib/retrieval_node/git-mirrors
```

`POOL_SIZE` and `ECTO_IPV6` are also read from this file if you need to
override their defaults (see `config/runtime.exs`).

### Backup destination — `/etc/retrieval_node/backup-env`

Optional, read by `retrieval_node-backup.service`:

```
BACKUP_DIR=/mnt/nvme/retrieval_node-backups
BACKUP_RETENTION_DAYS=14
```

## Build -> deploy flow

Run on the arm64 production/build box, as a non-root deploy user with a
checkout of the tagged commit:

```
scripts/build_arm64.sh
# ... prints the release tarball path, e.g.
#   _build/prod/retrieval_node-0.1.0.tar.gz

sudo scripts/deploy.sh _build/prod/retrieval_node-0.1.0.tar.gz
```

`build_arm64.sh`:
1. Hard-fails if not run on `aarch64`, or if glibc is older than 2.31.
2. `mix deps.get --only prod` + `mix compile` (`MIX_ENV=prod`) — this is
   where the tree-sitter NIF actually compiles via `cargo build` on-device.
3. Verifies the tree-sitter NIF `.so` and EXLA's `.so` are ARM aarch64 ELF
   (`file` command) — hard-fails on any x86-64 hit, which usually means a
   stale `_build/`/`deps/` directory leaked in from a dev machine.
4. Runs `mix rn.grammars.prefetch` to compile the tree-sitter grammar cache
   for the fixed language allowlist.
5. Copies that cache into `rel/overlays/grammar-cache` so `mix release`
   bakes it into the tarball (a fresh host boots correctly with no external
   cache directory required).
6. `mix release --overwrite`, then re-verifies `beam.smp` inside the
   assembled release is ARM aarch64 ELF.

`deploy.sh`:
1. Unpacks the tarball to `/opt/retrieval_node/releases/<timestamp>/`.
2. Atomically repoints `/opt/retrieval_node/current` (`ln -sfn`).
3. Sources `/etc/retrieval_node/env` (same file the systemd unit loads via
   `EnvironmentFile=`) and runs
   `bin/retrieval_node eval "RetrievalNode.Release.migrate()"` against the
   *new* release's code while the *old* release is still the one bound to
   the port — this is the standard mix-release migration order. It's safe
   for additive migrations (new columns/tables/indexes the old code
   ignores); migrations that drop/rename columns the old code still reads
   need a maintenance window instead of a plain deploy. If migration fails,
   the script aborts **before** restarting the service, so the old release
   keeps running untouched.
4. `systemctl restart retrieval_node`.
5. Polls `http://localhost:4000/healthz` until it returns 200 or the
   60s timeout is hit (nonzero exit + a `journalctl -u retrieval_node`
   hint on timeout — the previous release is left in place; repoint
   `/opt/retrieval_node/current` manually to roll back if needed).

## Disk layout

- `/opt/retrieval_node/releases/<timestamp>/` — extracted release tarballs.
- `/opt/retrieval_node/current` — symlink to the active release, flipped by
  `scripts/deploy.sh`.
- `/var/lib/retrieval_node/git-mirrors/` — bare git mirrors
  (`lib/retrieval_node/ingest/git_mirror.ex`), owned by the `retrieval_node`
  service user, created by `deploy/setup_postgres.sh`.
- `/var/lib/postgresql/18/main/` — standard OS-package Postgres data dir,
  untouched by app deploys.

## Dev (x86-64) deltas

Dev runs from the checked-out working tree, not a release:

- **No ELF verification step.** Both the tree-sitter NIF and EXLA's `xla`
  dep have first-class x86_64-linux-gnu precompiled binaries, so
  `mix deps.get && mix compile` just works — the `file`-command gate in
  `scripts/build_arm64.sh` only exists for the arm64 cross-build risk, which
  doesn't apply when the host is the only arch it will ever run on.
- **`mix phx.server`** directly for iteration — no `mix release`, no
  systemd unit, no `/opt/retrieval_node` disk layout.
- **Grammar cache** uses the default `~/.cache/tree-sitter-language-pack/`
  (`XDG_CACHE_HOME` is left unset; there's no release-packaging step that
  needs a pinned path). `mix rn.grammars.prefetch` can still be run once
  locally, or left to lazy on-demand compilation — dev tolerates an
  occasional first-use pause that would be unacceptable in prod.
- **Postgres**: this devcontainer runs Postgres on a non-default port —
  pass `PGPORT=5433 mix ...` (or whatever the container currently uses; see
  `config/dev.exs`) rather than the prod-default 5432.
- **No `EnvironmentFile`/`/etc/retrieval_node` secrets** — dev reads
  `config/dev.exs` (hardcoded dev `secret_key_base`, etc.) instead.
