#!/usr/bin/env bash
#
# Deploy a retrieval_node release tarball (built by scripts/build_arm64.sh) to
# this host: unpack under /opt/retrieval_node/releases/<timestamp>/, flip the
# /opt/retrieval_node/current symlink atomically, run Ecto migrations via the
# new release, restart the systemd service, and wait for /healthz to report
# ready before returning success.
#
# Usage: sudo scripts/deploy.sh <path-to-release-tarball>
#
# Run as root (or via sudo) — it writes under /opt/retrieval_node and calls
# systemctl. See deploy/README.md for the full build -> deploy flow and
# deploy/retrieval_node.service for the unit this restarts.
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

tarball="${1:-}"
[ -n "$tarball" ] || die "usage: $0 <path-to-release-tarball>"
[ -f "$tarball" ] || die "tarball not found: $tarball"

deploy_user="${RETRIEVAL_NODE_USER:-retrieval_node}"
deploy_group="${RETRIEVAL_NODE_GROUP:-retrieval_node}"
base_dir="${RETRIEVAL_NODE_BASE_DIR:-/opt/retrieval_node}"
service_name="${RETRIEVAL_NODE_SERVICE:-retrieval_node}"
# Matches config/runtime.exs `PORT` (defaults to 4000 there too).
health_port="${PORT:-4000}"
health_url="http://localhost:${health_port}/healthz"
health_timeout="${HEALTH_TIMEOUT_SECONDS:-60}"

releases_dir="$base_dir/releases"
current_link="$base_dir/current"
release_ts="$(date -u +%Y%m%d%H%M%S)"
release_dir="$releases_dir/$release_ts"
# Same file retrieval_node.service loads via EnvironmentFile= — `bin/*
# eval` below runs outside systemd, so it needs DATABASE_URL/SECRET_KEY_BASE
# (required by config/runtime.exs) sourced into this shell explicitly.
env_file="${RETRIEVAL_NODE_ENV_FILE:-/etc/retrieval_node/env}"

log "unpacking $tarball -> $release_dir"
mkdir -p "$release_dir"
tar -xzf "$tarball" -C "$release_dir"

if command -v chown >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
  chown -R "$deploy_user:$deploy_group" "$release_dir"
fi

log "repointing $current_link -> $release_dir"
ln -sfn "$release_dir" "$current_link"

if [ -f "$env_file" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
else
  die "env file not found: $env_file (required for migrations — see deploy/README.md)"
fi

# Migrations run against the live DB using the *new* release's code while the
# *old* release is still the one bound to the port (systemctl hasn't
# restarted yet). That's the standard mix-release migration order and is
# safe for additive migrations (new columns/tables/indexes the old code just
# ignores); it is NOT safe for migrations that drop/rename columns the old
# code still reads — coordinate those with a maintenance window instead of
# a plain deploy. See deploy/README.md.
#
# Failing here aborts *before* systemctl restart, so the old release keeps
# running untouched — nothing to roll back beyond fixing the migration and
# re-running this script.
log "running migrations: $current_link/bin/$service_name eval \"RetrievalNode.Release.migrate()\""
if ! "$current_link/bin/$service_name" eval "RetrievalNode.Release.migrate()"; then
  die "migration failed — old release is still running untouched (not restarted).
Fix the migration, then re-run: sudo $0 $tarball"
fi

log "systemctl restart $service_name"
systemctl restart "$service_name"

log "waiting for $health_url (timeout ${health_timeout}s)"
elapsed=0
until curl -fsS -o /dev/null -m 2 "$health_url" 2>/dev/null; do
  if [ "$elapsed" -ge "$health_timeout" ]; then
    echo
    die "$health_url did not return 200 within ${health_timeout}s.
Check the service: journalctl -u $service_name -n 200 --no-pager
The previous release is still at whatever $current_link pointed to before this
run — inspect $releases_dir and re-point $current_link manually if you need to
roll back, then 'systemctl restart $service_name'."
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

log "healthy: $health_url"
log "deployed $release_dir (current -> $(readlink -f "$current_link"))"
