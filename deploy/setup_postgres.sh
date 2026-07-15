#!/usr/bin/env bash
#
# One-time host setup for retrieval_node's Postgres 18 + pgvector, and the
# git-mirrors directory used by lib/retrieval_node/ingest/git_mirror.ex. Run
# once per production host as root (or via sudo). Safe to re-run: each step
# is idempotent.
#
# Target: self-hosted arm64 (Debian/Ubuntu, PGDG apt repo). See
# deploy/README.md for the full build -> deploy flow this fits into.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" = "0" ] || die "run as root (sudo $0)"

pg_major="${PG_MAJOR:-18}"
db_name="${RETRIEVAL_NODE_DB:-retrieval_node_prod}"
db_user="${RETRIEVAL_NODE_DB_USER:-retrieval_node}"
db_password="${RETRIEVAL_NODE_DB_PASSWORD:-}"
service_user="${RETRIEVAL_NODE_USER:-retrieval_node}"
service_group="${RETRIEVAL_NODE_GROUP:-retrieval_node}"
git_mirror_root="${GIT_MIRROR_ROOT:-/var/lib/retrieval_node/git-mirrors}"

[ -n "$db_password" ] || die "set RETRIEVAL_NODE_DB_PASSWORD before running (used to CREATE ROLE)."

# --- PGDG apt repo (arm64) ----------------------------------------------------
if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
  log "adding PGDG apt repo"
  . /etc/os-release
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    >/etc/apt/sources.list.d/pgdg.list
  apt-get update
else
  log "PGDG apt repo already present"
fi

# --- Install Postgres + pgvector ----------------------------------------------
log "installing postgresql-${pg_major} and pgvector"
apt-get install -y "postgresql-${pg_major}" "postgresql-${pg_major}-pgvector"

systemctl enable --now postgresql

# --- Service user --------------------------------------------------------------
if ! id "$service_user" >/dev/null 2>&1; then
  log "creating system user $service_user"
  useradd --system --home-dir "/opt/retrieval_node" --shell /usr/sbin/nologin \
    --user-group --create-home "$service_user"
else
  log "system user $service_user already exists"
fi

# --- Database role + database ---------------------------------------------------
run_as_postgres() { sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"; }

if ! run_as_postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${db_user}'" | grep -q 1; then
  log "creating role $db_user"
  # Password goes in via psql's :'var' substitution (a properly-quoted SQL
  # string literal, unlike bare :var) fed over stdin as a -v binding, not
  # interpolated into the SQL text or argv — psql -v values never appear in
  # /proc/*/cmdline the way a `-c "...'${db_password}'..."` argument would.
  run_as_postgres -v db_user="$db_user" -v db_password="$db_password" <<'SQL'
CREATE ROLE :"db_user" WITH LOGIN PASSWORD :'db_password';
SQL
else
  log "role $db_user already exists (not touching password — set it manually if it needs to change)"
fi

if ! run_as_postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" | grep -q 1; then
  log "creating database $db_name owned by $db_user"
  # Same psql :"var" identifier-quoting as the role block above — no shell
  # interpolation into SQL text.
  run_as_postgres -v db_name="$db_name" -v db_user="$db_user" <<'SQL'
CREATE DATABASE :"db_name" OWNER :"db_user";
SQL
else
  log "database $db_name already exists"
fi

# The `vector` extension itself is NOT created here — retrieval_node's Ecto
# migrations run `CREATE EXTENSION IF NOT EXISTS vector` as part of
# `bin/retrieval_node eval "RetrievalNode.Release.migrate()"` (or
# `mix ecto.migrate` in dev). Creating it here would drift from what the
# migration history says is present.
log "NOTE: 'CREATE EXTENSION vector' is applied by ecto migrations, not this script."

# --- git-mirrors directory -------------------------------------------------------
log "creating $git_mirror_root (owned by $service_user:$service_group)"
install -d -o "$service_user" -g "$service_group" -m 0750 "$git_mirror_root"

# --- Backup script -----------------------------------------------------------
log "installing backup script to /usr/local/bin/retrieval_node-backup.sh"
install -m 0755 "$script_dir/backup_postgres.sh" /usr/local/bin/retrieval_node-backup.sh

# Pre-create the default backup dir owned by `postgres` (the OS user
# retrieval_node-backup.service runs as) so the first timer-triggered run
# doesn't fail trying to mkdir under /var/backups. 0700 because dumps
# contain pre-scrub content (see backup_postgres.sh's umask 077) — matches
# the mode backup_postgres.sh itself enforces on every run.
backup_dir="${BACKUP_DIR:-/var/backups/retrieval_node}"
log "creating $backup_dir (owned by postgres:postgres)"
install -d -o postgres -g postgres -m 0700 "$backup_dir"

log "postgres + git-mirrors setup complete."
echo "  database: $db_name (role: $db_user)"
echo "  git mirrors: $git_mirror_root"
echo "  Next: write /etc/retrieval_node/env (see deploy/README.md), then scripts/deploy.sh <tarball>"
