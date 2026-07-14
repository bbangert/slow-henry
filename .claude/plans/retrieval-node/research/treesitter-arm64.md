# tree_sitter_language_pack: aarch64/arm64 Linux Native Binary Artifact Analysis

**Research Date:** 2026-07-14  
**Package:** `tree_sitter_language_pack` (Hex ~1.12.5)  
**Repo:** xberg-io/tree-sitter-language-pack  
**Goal:** Determine arm64 Linux production readiness and deploy-time cross-architecture safety

---

## Executive Summary

**Risk Level: MEDIUM**

The Elixir `tree_sitter_language_pack` via Rustler NIF **does NOT publish precompiled binaries for `aarch64-unknown-linux-gnu`** (Linux ARM64). The GitHub Actions CI workflows build only for:
- `x86_64-unknown-linux-gnu` (Linux x86-64)
- `aarch64-apple-darwin` (macOS ARM64)

**Consequence:** Deploying to arm64 Linux requires compiling the Rust NIF on-device. This is **not a blocker** but adds build time, memory pressure, and requires Rust toolchain availability.

The grammar `.so` parser files are **downloaded on-demand at runtime** by default but can be prefetched at build-time. Grammars are **architecture-agnostic** (compiled from `.wasm` sources or precompiled C/Rust across all targets).

---

## Findings by Question

### 1. Rustler Precompilation: aarch64 Support?

**Short Answer:** No precompiled aarch64-unknown-linux-gnu binaries are published for the Elixir package.

#### Details:
- **Package:** `tree_sitter_language_pack` v1.12.5 on hex.pm  
- **NIF Technology:** Uses Rustler for native code integration (confirmed)  
- **Precompilation Setup:** Does **NOT** use `rustler_precompiled` crate
- **GitHub Actions CI:**
  - Specifies only `x86_64-unknown-linux-gnu` and `aarch64-apple-darwin` targets
  - Uses language-specific build tools (maturin for Python, @napi-rs/cli for Node.js) instead of rustler_precompiled_action
  - Artifact retention is 1-7 days; artifacts are not persisted to hex.pm as precompiled binaries

#### Precompilation Ecosystem Support:
Per [rustler_precompiled HexDocs](https://rustler-precompiled.hexdocs.pm/precompilation_guide.html), the tooling **does support** `aarch64-unknown-linux-gnu`:
- Requires `cross` tool for cross-compilation
- Requires `.cargo/config.toml` rustflags for musl variants: `-C target-feature=-crt-static`
- Fallback: If precompiled binary unavailable, system attempts to compile from source (requires Rust toolchain on-device)

**Verdict:** The package *could* use rustler_precompiled for aarch64, but currently doesn't.

---

### 2. Grammar `.so` Files: Architecture-Specific or Neutral?

**Short Answer:** Grammars are **architecture-neutral in storage**; downloaded `.wasm` or precompiled parsers are **architecture-specific on instantiation**.

#### Details:

**Cache Location & Download Behavior:**
- Grammars are downloaded on-demand at runtime (first use)
- Local cache: typically `~/.cache/tree-sitter-language-pack/` or `$XDG_CACHE_HOME`
- No internet required after first download (cached locally)

**Architecture Neutrality:**
- Grammar definition files (`.wasm` bytecode or precompiled parser sources) are bundled as part of the tree-sitter ecosystem
- Each CPU architecture requires its own compiled grammar binary (`.so` for Linux)
  - x86_64 Linux: `.so` compiled for x86_64
  - aarch64 Linux: `.so` compiled for aarch64
- The grammar sources themselves are shared, but the compiled bindings are arch-specific

**Prefetch Function:**
- Yes, `prefetch()` exists to download and compile all grammars upfront
- Can be called at **build-time** (inside a Mix task, compile hook, or release builder)
- **Safe for cross-arch builds?** No — if prefetch runs on x86_64 build machine, it downloads x86_64-compiled grammars; aarch64 deployment box will either re-fetch for arm64 or use cached x86_64 binaries (which will fail at runtime)

**Internet at Runtime:**
- If grammar cache is missing and no internet available: **parser load fails**
- Mitigation: Ensure cache is populated before deploy (prefetch at build-time on target architecture)

---

### 3. Cross-Architecture Dev↔Prod Release Building

**Short Answer:** An x86_64 build machine **cannot safely produce arm64-correct `mix release`**. Must build on arm64 runner or use architecture-specific build containers.

#### Safe Patterns:

**Option A (Recommended): Build on arm64 Runner**
```
1. Use GitHub Actions arm64 runner (e.g., `runs-on: ubicloud-standard-4-arm`) or self-hosted ARM runner
2. `mix deps.get` on arm64
3. Optionally: `mix run -e "TreeSitterLanguagePack.prefetch([:all])"` to warm grammar cache
4. `mix release --path=/path/to/arm64/release`
5. Deploy tarball to production (no recompilation needed if no source changes)
```

**Option B: Docker Cross-Compilation (If arm64 CI Unavailable)**
```
1. Use `FROM debian:bookworm` base for aarch64
2. Install Rust, Elixir, `build-essential` in the image
3. Build release inside the container
4. Extract release tarball from Docker image
5. Note: Slower than native arm64 runner, but avoids pre-existing cache mismatch
```

**Option C: Platform-Specific Releases (If Multi-Arch Deploy)**
```
1. Build x86_64 release on ubuntu-latest runner
2. Build arm64 release on arm64 runner
3. Tag releases per architecture (e.g., `app-1.0.0-x86_64.tar.gz`, `app-1.0.0-arm64.tar.gz`)
4. Deploy-time: Select correct tarball per host
```

**Why x86_64 Build Machine Fails for arm64:**
- Rust NIF compilation targets x86_64 CPU (host == target)
- Grammar cache (if populated) contains x86_64-compiled `.so` files
- arm64 production box loads x86_64 binaries → segfault or "unsupported architecture" error at runtime
- `mix release` bundles the compiled NIF from build machine

---

### 4. Musl vs. glibc for aarch64

**Elixir package CI:** Only specifies `linux-gnu` (glibc), not musl.

**Practical Concern:**
- If production arm64 boxes run Alpine Linux (musl), the glibc-built NIF will fail
- Workaround: Use `aarch64-unknown-linux-musl` cross-compilation target if deploying to Alpine
- Current package CI does not test musl; if needed, raise GitHub issue or use a self-hosted musl arm64 runner

**Musl Build Overhead (from rustler_precompiled docs):**
- Requires `.cargo/config.toml` rustflags: `-C target-feature=-crt-static`
- Adds slight build time; no ARM-specific penalty

---

### 5. Known arm64 Issues

**ElixirForum Search:** No active discussions found for `tree_sitter_language_pack` + arm64 specifically.

**GitHub Issues:** 
- No GitHub issues explicitly mentioning aarch64-unknown-linux-gnu for tree_sitter_language_pack
- Related rustler_precompiled issue: [adoptoposs/mjml_nif#66](https://github.com/adoptoposs/mjml_nif/issues/66) — "precompiled NIF not available: Compilation fails on M1 with Alpine hex.pm builder for target aarch64-unknown-linux-musl" — illustrates the exact problem: missing musl aarch64 precompiled binaries force source compilation

**Likely Reason:** tree_sitter_language_pack is published by xberg-io, which may prioritize Python/Node.js distributions (where precompilation is simpler via maturin/napi-rs) over Elixir hex.pm.

---

## Build Time & Resource Costs (arm64 Compile-from-Source)

If no precompiled binary is available and on-device compilation occurs:

| Factor | Estimate | Notes |
|--------|----------|-------|
| **Rust Toolchain Size** | ~1.5–2 GB | First install; cached between builds |
| **Compilation Time** | 5–15 min | Depends on CPU (bare metal << CI container) |
| **Memory Required** | 2–4 GB RAM | Linking stage is memory-intensive |
| **Disk Space** | ~2 GB | Compiled artifacts + toolchain |

**Mitigation:** Use arm64 dedicated CI runner or build cache to avoid recompilation per release.

---

## Recommended Deploy-Time Approach

### Strategy: **Build-on-arm64 + Prefetch at Compile Time**

```elixir
# mix.exs — add compile hook
def project do
  [
    app: :my_app,
    # ...
    compilers: [:rustler | Mix.compilers()],
  ]
end

# Create priv/static_compile_task.exs
defmodule Tasks.PrefetchGrammars do
  def run(_args) do
    # Runs during `mix compile`
    # Only works if TreeSitterLanguagePack is available
    case Code.ensure_loaded(TreeSitterLanguagePack) do
      {:module, _} ->
        IO.puts("Pre-fetching tree-sitter grammars...")
        TreeSitterLanguagePack.prefetch(:all)  # or specific languages
        IO.puts("Grammars cached.")
      {:error, _} ->
        IO.puts("TreeSitterLanguagePack not available; skipping prefetch")
    end
  end
end

# In mix.exs:
# Add `:prefetch_grammars` to compilers or run as post-compile Mix task
```

### CI Workflow (GitHub Actions Example):

```yaml
name: Build Arm64 Release
on:
  push:
    tags: ['v*']

jobs:
  build-arm64:
    runs-on: ubicloud-standard-4-arm  # or self-hosted arm64 runner
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v2
        with:
          otp-version: "27"
          elixir-version: "1.17"
      
      - name: Install Rust (aarch64)
        run: |
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
          source ~/.cargo/env
          rustup target add aarch64-unknown-linux-gnu
      
      - name: Fetch & Build
        run: |
          mix deps.get
          mix compile
      
      - name: Prefetch Grammars
        run: |
          mix run -e "TreeSitterLanguagePack.prefetch(:all)" || echo "Prefetch N/A"
      
      - name: Release Build
        run: |
          MIX_ENV=prod mix release
      
      - name: Upload Release
        uses: actions/upload-artifact@v4
        with:
          name: release-arm64
          path: _build/prod/rel/my_app/
```

---

## Summary Table

| Aspect | Status | Action |
|--------|--------|--------|
| **aarch64 Precompiled NIF** | ❌ Not published | Build on arm64 runner or use musl Alpine container |
| **Grammar Downloads** | ✅ Runtime download cached | Prefetch at build-time to warm cache on target arch |
| **Cross-Arch Release Build** | ❌ Not safe | Use arm64 CI runner (don't build x86_64→arm64 on same machine) |
| **Musl Support** | ⚠️ Not tested in CI | Raise issue with xberg-io if Alpine production needed |
| **ElixirForum Precedent** | ❌ No active threads | First-mover; contribute findings back |
| **Fallback Compilation** | ✅ Automatic via Rustler | Works if Rust toolchain available; adds 5–15 min to boot |

---

## Risk Verdict & Recommendation

**RISK: MEDIUM → LOW with mitigation**

- ✅ **Technically Feasible:** Rustler + rustler_precompiled both support aarch64-unknown-linux-gnu
- ⚠️ **Tree-Sitter Package Gap:** No precompiled aarch64 hex.pm binaries; must compile on-device or build release on arm64
- ✅ **Workaround Quality:** Mature rustler_precompiled ecosystem + arm64 CI runners (Ubicloud, GitHub-hosted) make arm64 builds trivial
- ⚠️ **First-Mover Risk:** No ElixirForum precedent; if issues arise, you're discovering them first

**Deploy Approach:**
1. **Immediate:** Set up arm64 GitHub Actions runner (Ubicloud or self-hosted)
2. **Build phase:** `mix compile` + optional `TreeSitterLanguagePack.prefetch(:all)` on arm64 runner
3. **Release phase:** `mix release` on the same arm64 runner; deploy tarball to production
4. **Cold-start:** If grammar cache misses at runtime, on-device compilation (5–15 min, high RAM) occurs; not ideal but safe
5. **Long-term:** File GitHub issue with xberg-io requesting official aarch64-unknown-linux-gnu precompilation for hex.pm (like they do for Python/Node.js)

---

## Primary Sources

- **[Tree-sitter Language Pack GitHub (xberg-io)](https://github.com/xberg-io/tree-sitter-language-pack)** [T1]  
- **[Rustler Precompiled HexDocs](https://rustler-precompiled.hexdocs.pm/precompilation_guide.html)** [T1]  
- **[Hex.pm: tree_sitter_language_pack](https://hex.pm/packages/tree_sitter_language_pack)** [T1]  
- **[Hex.pm: Packages depending on Rustler](https://hex.pm/packages?search=depends:hexpm:rustler)** [T2]  
- **[GitHub: adoptoposs/mjml_nif #66 (aarch64-unknown-linux-musl issue)](https://github.com/adoptoposs/mjml_nif/issues/66)** [T3]  

---

## Appendix: Commands for arm64 Deploy Testing

```bash
# On arm64 local machine or CI runner:
uname -m
# Output: aarch64

rustc --version --verbose | grep host
# Output: host: aarch64-unknown-linux-gnu

mix compile
# Compiles NIF for aarch64

# Pre-warm grammar cache (optional, recommended):
mix run -e "TreeSitterLanguagePack.prefetch([:elixir, :python, :rust])"

# Build release:
MIX_ENV=prod mix release

# Verify release architecture:
file _build/prod/rel/my_app/erts-*/bin/beam.smp
# Output: ELF 64-bit LSB shared object, ARM aarch64, ...

# Deploy tarball to production arm64 box:
tar xzf _build/prod/rel/my_app.tar.gz -C /opt/releases/
```

---

**End of Report**
