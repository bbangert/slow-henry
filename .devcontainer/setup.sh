#!/usr/bin/env bash
set -euo pipefail

# Activate mise in interactive shells (must happen here, after devcontainer
# features like common-utils have finished writing ~/.bashrc / ~/.zshrc)
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
echo 'eval "$(mise activate zsh)"'  >> ~/.zshrc

# Bring up the PostgreSQL 18 cluster (installed WITH pgvector in the Dockerfile)
# on the standard port 5432 and give the `postgres` superuser a known password so
# the app can connect over TCP (config/dev.exs, config/test.exs). The cluster is
# auto-created by postgresql-common when postgresql-18 is installed; here we just
# start it and set the password. `postStartCommand` restarts it on later boots.
setup_postgres() {
  # Query profiling: pg_stat_statements must be preloaded before cluster start
  # (a running cluster needs a restart to pick it up). The extension itself is
  # created per-database by the app's migrations/dev bootstrap or manually:
  #   CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  sudo pg_conftool 18 main set shared_preload_libraries pg_stat_statements

  sudo pg_ctlcluster 18 main start 2>/dev/null || true

  # Wait for the cluster to accept connections on its unix socket (peer auth as
  # the postgres OS user), then set the TCP password.
  local ready=""
  for _ in $(seq 1 15); do
    if sudo su postgres -c "psql -p 5432 -h /var/run/postgresql -tAc 'SELECT 1'" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ -z "${ready}" ]; then
    echo "warning: PostgreSQL 18 did not become ready on port 5432" >&2
    return 0
  fi

  sudo su postgres -c "psql -p 5432 -h /var/run/postgresql -c \"ALTER USER postgres PASSWORD 'postgres';\""
  sudo su postgres -c "psql -p 5432 -h /var/run/postgresql -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'"
}

setup_postgres

mise install

# Export tool paths for the rest of this script (mise activate relies on
# prompt hooks which don't fire in non-interactive scripts)
eval "$(mise env)"
mix local.hex --force
mix local.rebar --force

# Fetch deps if the project has been generated already
if [ -f mix.exs ]; then
  mix deps.get
fi
