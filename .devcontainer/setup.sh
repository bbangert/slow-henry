#!/usr/bin/env bash
set -euo pipefail

# Activate mise in interactive shells (must happen here, after devcontainer
# features like common-utils have finished writing ~/.bashrc / ~/.zshrc)
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
echo 'eval "$(mise activate zsh)"'  >> ~/.zshrc

# Install the pgvector extension for the Postgres server that the devcontainer
# postgresql feature installed. The feature installs the server but not
# pgvector, which is the app's vector store (Postgres + pgvector, HNSW index).
# Key the package to the installed major version; fall back to a source build.
install_pgvector() {
  local pg_major
  pg_major="$(ls -1 /usr/lib/postgresql 2>/dev/null | sort -V | tail -1 || true)"
  if [ -z "${pg_major}" ] && command -v pg_config >/dev/null 2>&1; then
    pg_major="$(pg_config --version | grep -oE '[0-9]+' | head -1)"
  fi
  if [ -z "${pg_major}" ]; then
    echo "warning: no Postgres install detected; skipping pgvector" >&2
    return 0
  fi

  if dpkg -s "postgresql-${pg_major}-pgvector" >/dev/null 2>&1; then
    return 0
  fi

  sudo apt-get update
  if sudo apt-get install -y "postgresql-${pg_major}-pgvector"; then
    return 0
  fi

  # Fallback: build pgvector from source against the installed server.
  echo "pgvector package unavailable; building from source" >&2
  sudo apt-get install -y "postgresql-server-dev-${pg_major}"
  local tmp
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/pgvector/pgvector.git "${tmp}/pgvector"
  make -C "${tmp}/pgvector"
  sudo make -C "${tmp}/pgvector" install
  rm -rf "${tmp}"
}

install_pgvector

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
