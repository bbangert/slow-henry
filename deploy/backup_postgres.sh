#!/usr/bin/env bash
#
# Nightly pg_dump for retrieval_node's database, invoked by
# deploy/retrieval_node-backup.service (triggered by
# deploy/retrieval_node-backup.timer). Dumps to a configurable path — point
# BACKUP_DIR at NVMe-backed storage — with simple N-day rotation.
set -euo pipefail

# pending_chunks.raw_content holds pre-scrub content until redaction runs, so
# a mid-ingest dump can contain plaintext secrets — keep every file this
# script creates private to its owner (0600 files, 0700 dirs) for the full
# retention window.
umask 077

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

db_name="${RETRIEVAL_NODE_DB:-retrieval_node_prod}"
backup_dir="${BACKUP_DIR:-/var/backups/retrieval_node}"
retention_days="${BACKUP_RETENTION_DAYS:-14}"

command -v pg_dump >/dev/null 2>&1 || die "pg_dump not found on PATH"

mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$backup_dir/${db_name}-${stamp}.sql.gz"

# Runs as the `postgres` OS user (see retrieval_node-backup.service) so this
# authenticates via the default local peer-auth mapping (no --host/--username,
# no password needed) and, as a Postgres superuser, can always dump the db
# regardless of the app role's own permissions.
log "dumping $db_name -> $dest"
pg_dump --no-owner "$db_name" | gzip >"$dest"

log "rotating backups older than ${retention_days}d in $backup_dir"
find "$backup_dir" -maxdepth 1 -name "${db_name}-*.sql.gz" -mtime "+${retention_days}" -print -delete

log "backup complete: $dest"
