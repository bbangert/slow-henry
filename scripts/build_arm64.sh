#!/usr/bin/env bash
#
# On-device ARM64 build pipeline for retrieval_node (Phase 8).
#
# MUST run on the actual aarch64 build/production box — never cross-build.
# The tree_sitter_language_pack Rustler NIF has no aarch64 hex precompiled
# binary (it falls back to on-device `cargo build`), and EXLA's XLA .so is
# fetched for a specific target triple. An x86-64 artifact loaded on an
# aarch64 host segfaults the whole BEAM VM at runtime with no compile-time
# warning — see .claude/plans/retrieval-node/research/design-build.md.
#
# v1 has no Erlang distribution / peer nodes: this script does not generate
# or set a RELEASE_COOKIE (see rel/env.sh.eex, RELEASE_DISTRIBUTION=none).
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# --- Arch guard --------------------------------------------------------------
arch="$(uname -m)"
if [ "$arch" != "aarch64" ]; then
  die "build_arm64.sh must run on an aarch64 host (uname -m reported: $arch).
Cross-building is not supported: the tree-sitter NIF and EXLA's .so are
architecture-specific and must be compiled on-device. Run this on the arm64
build/production box instead."
fi
log "arch OK: aarch64"

# --- glibc guard (xla v0.9.1+ requires >= 2.31) -------------------------------
glibc_version="$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
[ -n "$glibc_version" ] || die "could not parse glibc version from 'ldd --version'."
glibc_major="${glibc_version%%.*}"
glibc_minor="${glibc_version##*.}"
if [ "$glibc_major" -lt 2 ] || { [ "$glibc_major" -eq 2 ] && [ "$glibc_minor" -lt 31 ]; }; then
  die "glibc >= 2.31 required (xla v0.9.1+), found $glibc_version."
fi
log "glibc $glibc_version OK (>= 2.31)"

# --- Build environment ---------------------------------------------------------
export MIX_ENV=prod
export XLA_TARGET_PLATFORM=aarch64-linux-gnu

# Build-time grammar cache staging dir. Populated by `mix rn.grammars.prefetch`
# below, then copied into rel/overlays/grammar-cache before `mix release` so
# the release tarball carries its own cache (rel/env.sh.eex points
# XDG_CACHE_HOME at $RELEASE_ROOT/grammar-cache by default at runtime).
: "${XDG_CACHE_HOME:=/opt/retrieval_node/grammar-cache}"
export XDG_CACHE_HOME
mkdir -p "$XDG_CACHE_HOME"
log "XDG_CACHE_HOME=$XDG_CACHE_HOME"

log "mix deps.get --only prod"
mix deps.get --only prod

log "mix compile (MIX_ENV=prod) — compiles tree-sitter NIF on-device, expect 5-15 min"
mix compile

# --- ELF verification helper --------------------------------------------------
# Hard-fails the build the moment any arch-sensitive artifact is not aarch64,
# rather than shipping a segfault-on-boot release. See design-build.md §1.6.
check_arm64_elf() {
  path="$1"
  label="$2"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    die "expected artifact not found for $label (searched under _build/prod). A missing .so usually means the on-device compile step above failed silently."
  fi
  out="$(file "$path")"
  printf '    %s: %s\n' "$label" "$out"
  case "$out" in
    *"ARM aarch64"*) ;;
    *)
      die "$label is not ARM aarch64 ELF ($out). A stale x86-64 _build/ or deps/ directory likely leaked in from a dev machine — remove _build/prod and deps/ and rebuild from clean."
      ;;
  esac
}

log "ELF verification (deps): tree_sitter_language_pack NIF + EXLA .so"
ts_so="$(find _build/prod/lib/tree_sitter_language_pack -type f -name '*.so' 2>/dev/null | head -1)"
check_arm64_elf "$ts_so" "tree_sitter_language_pack NIF .so"

exla_so="$(find _build/prod/lib/exla -type f -name '*.so' 2>/dev/null | head -1)"
check_arm64_elf "$exla_so" "EXLA .so"

log "mix rn.grammars.prefetch"
mix rn.grammars.prefetch

log "staging grammar cache into rel/overlays/grammar-cache"
mkdir -p rel/overlays/grammar-cache
cp -a "$XDG_CACHE_HOME/." rel/overlays/grammar-cache/

log "mix release --overwrite"
mix release --overwrite

release_dir="_build/prod/rel/retrieval_node"
[ -d "$release_dir" ] || die "expected release directory not found: $release_dir"

log "ELF verification (release): beam.smp"
beam_smp="$(find "$release_dir" -type f -name 'beam.smp' 2>/dev/null | head -1)"
check_arm64_elf "$beam_smp" "beam.smp (assembled release)"

# start_erl.data is "<erts_vsn> <release_vsn>" — the second field is the app
# release version used in the tarball filename by the :tar release step.
version="$(awk '{print $2}' "$release_dir/releases/start_erl.data" 2>/dev/null)"
tarball="_build/prod/retrieval_node-${version:-unknown}.tar.gz"

echo
log "Build complete."
if [ -f "$tarball" ]; then
  echo "  Release tarball: $tarball"
else
  echo "  Release directory: $release_dir"
  echo "  (expected tarball not found at $tarball — check the :tar release step in mix.exs)"
fi
echo "  Next: scripts/deploy.sh <path-to-tarball-or-release-dir>"
