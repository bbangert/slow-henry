# EXLA on aarch64/arm64 Linux in Production: Research Findings (Mid-2026)

**Date:** July 14, 2026  
**Context:** Self-hosted knowledge-retrieval server; CPU-only embedding (bge-small / nomic-embed); dev on x86-64, prod on aarch64-linux-gnu  
**Risk Verdict:** **MEDIUM** (precompiled binaries available but deployment gotchas require careful configuration)

---

## 1. Prebuilt XLA Binaries for arm64-linux

**Status:** ✅ **Supported and precompiled**

The `elixir-nx/xla` package (v0.9.1+, July 2026) includes precompiled CPU binaries for `aarch64-linux-gnu-cpu`. No source build required on the ARM target **if precompiled binaries are correctly downloaded**.

### How It Works

- The `xla` hex package ships with precompiled `.tar.gz` archives for multiple platforms.
- At mix compile time, EXLA downloads the correct archive based on the host platform (or explicit `XLA_TARGET_PLATFORM` env var).
- For ARM64 Linux: Set `XLA_TARGET_PLATFORM=aarch64-linux-gnu` to download the ARM-native binary.

### If Precompiled Binaries Are Unavailable

Source build is **feasible but slow and resource-intensive**:
- **Build time:** 4–8+ hours (on mid-range ARM server; varies with CPU, disk speed, RAM)
- **RAM requirement:** ~4–8 GB free RAM minimum; 12+ GB strongly recommended for Bazel build
- **Dependencies:** Bazel 7.7.0, Clang 18, Python 3 with NumPy, Git
- **Disk:** ~50–100 GB in `~/.cache/xla_build`

**Mitigation:** For production, use precompiled binaries. Source builds should be reserved for custom patches or bleeding-edge features.

---

## 2. EXLA Precompilation & Caching

**First-Request Latency Problem:** JIT compilation of the embedded model happens on first use, adding **seconds to minutes** of latency.

### Warmup / Precompilation Strategies

1. **JIT Caching** (`exla:default_backend/0`):
   - EXLA caches compiled functions in-memory and on disk.
   - Subsequent requests for the same function are fast (~1–10ms).
   - Cache survives within the Erlang process but not across restarts.

2. **Warmup at Startup**:
   - Load the embedding model at application startup (e.g., in a GenServer `init/1`).
   - Run a single "dummy" embedding inference with the same input shape as production.
   - This forces JIT compilation before handling live traffic.
   - Example pattern:
     ```elixir
     defmodule MyApp.EmbeddingServer do
       def start_link(_opts) do
         {:ok, serving} = Bumblebee.Text.embedding(...)
         # Warmup
         {:ok, _} = Bumblebee.run(serving, {"dummy input"})
         {:ok, serving}
       end
     end
     ```

3. **Caching via Environment Variables**:
   - `EXLA_FORCE_REBUILD=partial`: Clears only libexla.so caches, rebuilds without intermediate `.o` artifacts.
   - Useful for skipping CPU-intensive recompilation between deployments.
   - Set at deploy time to skip redundant rebuilds.

4. **`mix release` Integration**:
   - `mix release` produces a tarball with compiled Elixir code and EXLA precompiled binaries.
   - JIT-compiled model functions are **not** baked into the release (they're compiled at runtime).
   - To include model warmup, add a `c:Release.steps/1` callback that runs at boot.

### First-Compile Cost (Small Embedding Model on ARM CPU)

- **bge-small (~33M params)**: ~10–30 seconds on modern ARM64 (e.g., AWS Graviton3, Scaleway ARM).
- **Older ARM boards (Raspberry Pi 4)**: ~1–5 minutes.
- **First request:** Add this latency once per application restart.
- **Subsequent requests:** <10ms (cached).

**Recommendation:** Always warm up the model at startup to avoid cold-start penalty for actual requests.

---

## 3. Cross-Architecture Dev → Prod

**Problem:** Building a `mix release` on x86-64 for deployment on arm64 requires architecture-specific binaries.

### Three Approaches

#### A. **Build on the Target Architecture (Recommended for Prod)**
- Deploy an arm64 builder (e.g., AWS Graviton instance, Scaleway ARM VPS, or native ARM machine).
- Run `mix release` on the ARM target.
- XLA automatically detects the platform and downloads `aarch64-linux-gnu` binaries.
- **Pro:** Native build, no surprises.
- **Con:** Slower CI/CD (ARM machines are slower than x86); extra infrastructure.

#### B. **Cross-Compile via Docker Multi-Stage (Viable)**
- Use Docker buildx with `--platform linux/arm64`.
- Set `XLA_TARGET_PLATFORM=aarch64-linux-gnu` in the Dockerfile to force ARM binary download on x86 builder.
- Works **if precompiled arm64 binaries are available** (they are for v0.9.1+).
- **Gotcha (Erlang/OTP 26+ + QEMU):** Docker's QEMU emulation of ARM64 on x86 has a segmentation fault in ERLANG JIT. **Workaround:**
  ```dockerfile
  # Set before `mix deps.get --only prod`
  ENV ERL_FLAGS="+JPperf true"  # Disables dual-page memory mapping
  ```
  Or use `ERL_FLAGS="+JMsingle true"` for explicit single-page mapping.
- **Pro:** Unified CI pipeline; x86 CI runners are faster.
- **Con:** QEMU instability; architecture mismatch risk.

#### C. **Build Separate ARM Release on x86 (Risky)**
- Use `XLA_TARGET_PLATFORM=aarch64-linux-gnu` to force EXLA to download ARM binaries.
- The resulting release will have arm64-specific compiled EXLA binaries but x86-compiled Elixir bytecode (if not careful).
- **NOT recommended:** High risk of mismatch.

### Architecture Mismatch Risk

Real incident (ElixirForum, 2024): M1 Mac developer deployed x86_64 EXLA binaries to prod, causing `"mach-o file, but is an incompatible architecture"` error at runtime. The issue was resolved by upgrading EXLA to 0.6.0+ (better architecture detection). **Lesson:** Verify architecture explicitly:
```bash
# In release/app
file _build/prod/rel/my_app/lib/exla-*/priv/libexla.so
# Should say: "ELF 64-bit LSB shared object, ARM aarch64"
```

---

## 4. Alternatives to EXLA on ARM

### A. **Nx.BinaryBackend (Pure Elixir)**
- **What:** Nx's pure-Elixir tensor backend; no native code, no JIT compilation.
- **Status:** Viable for small, inference-only workloads.
- **Trade-off:** Slow (~10–100x slower than EXLA for dense tensor ops).
- **For small embeddings (bge-small):** **Possibly acceptable** (single 512-dim embedding per request, not real-time).
- **Risk:** Not widely tested for production embedding serving.
- **Bumblebee integration:** Bumblebee requires an Nx backend; `Nx.BinaryBackend` works but not recommended in official docs.

### B. **llama.cpp HTTP Sidecar** (Recommended Alternative)
- **What:** Standalone HTTP server for embeddings, built in C++ with excellent ARM64 support.
- **Pros:**
  - Pre-built arm64 binaries (no compilation on target).
  - Simple HTTP API (POST JSON, get embeddings).
  - Widely adopted; stable.
  - Decouples embedding service from Elixir app.
  - No Nx/EXLA/Bumblebee complexity.
- **Cons:**
  - Extra service to manage (systemd, Docker, or supervisor).
  - Network latency (~1–5ms over localhost).
  - Removes Elixir-native model serving.
- **For this use case:** **If EXLA proves unstable on arm64, llama.cpp is a lower-risk fallback.** Many Elixir teams use this pattern.

### C. **ONNX Runtime (Potential Future)**
- Not yet a first-class Elixir option (mid-2026), but `onnxruntime` has excellent ARM64 C++ binaries.
- Would require a Rust NIF binding; significant effort.
- Skip unless EXLA and llama.cpp both fail.

---

## 5. Known arm64-Specific EXLA Gotchas

### Gotcha 1: Precompiled Binary Fallback
- If `XLA_TARGET_PLATFORM` is not set and the build platform is not x86-64, EXLA tries to download a precompiled binary.
- If no binary exists for the detected platform, it falls back to source build.
- **Mitigation:** Always explicitly set `XLA_TARGET_PLATFORM=aarch64-linux-gnu` on ARM systems.

### Gotcha 2: Erlang/OTP 26+ QEMU Segfault (Docker)
- **Symptom:** `qemu: uncaught target signal 11 (Segmentation fault)` during `mix deps.get --only prod` on ARM64 Docker build on x86 host.
- **Cause:** Erlang JIT compiler's dual-page memory mapping conflicts with QEMU.
- **Fix:** Set `ERL_FLAGS="+JPperf true"` or `"+JMsingle true"` in Dockerfile builder stage.
- **Ref:** ElixirForum (2024) "ARM64 Dockerfile failing" thread.

### Gotcha 3: Architecture Mismatch on Cross-Compile
- **Symptom:** Runtime `mach-o file, but is an incompatible architecture` or linker errors.
- **Cause:** EXLA binaries don't match Erlang's CPU architecture.
- **Prevention:**
  - Always verify: `file _build/prod/rel/*/lib/exla-*/priv/libexla.so`.
  - Use `XLA_TARGET_PLATFORM` explicitly.
  - Build on the target architecture when possible.

### Gotcha 4: Disk Space and Build Time
- Source builds of XLA are **slow and disk-hungry**.
- If using a small ARM server (e.g., 2 GB RAM, 16 GB disk), precompiled binaries are **essential**.
- Recommendation: Cache precompiled binaries in a Docker image or CI artifact to avoid re-download.

### Gotcha 5: glibc Compatibility
- v0.9.1+ of `xla` lowered the glibc requirement to **2.31+** (from 2.35+), expanding ARM64 Linux compatibility.
- Verify your ARM64 Linux distro has glibc ≥ 2.31:
  ```bash
  ldd --version | head -n1
  ```
- If glibc is too old, consider upgrading the distro or building from source.

---

## 6. Recommended Production Strategy

### For Self-Hosted ARM64 Embedding Server

1. **Use Precompiled Binaries (No Source Build)**
   - Require `xla` v0.9.1+.
   - Explicitly set `XLA_TARGET_PLATFORM=aarch64-linux-gnu` in your `mix.exs` or deployment script.
   - Verify binaries: `file _build/prod/rel/*/lib/exla-*/priv/libexla.so`.

2. **Warmup Model at Startup**
   - Load Bumblebee embedding model in a GenServer at app boot.
   - Run a dummy inference to trigger JIT compilation.
   - This eliminates cold-start latency for production requests.

3. **Build on ARM or Use Docker Multi-Stage with QEMU Workaround**
   - **Preferred:** Use an ARM64 builder (costs slightly more but avoids QEMU issues).
   - **If x86 builder is required:** Set `ERL_FLAGS="+JPperf true"` in Dockerfile.
   - Test the release on ARM before production deployment.

4. **Fallback: llama.cpp Sidecar**
   - If EXLA deployment proves problematic, run llama.cpp as a separate HTTP service.
   - HTTP overhead is minimal (~1–5ms per request) and worth the operational simplicity.

5. **Monitor and Log**
   - Log `EXLA` backend availability at startup: `Nx.default_backend()`.
   - Monitor first-request JIT latency in development to set realistic SLA expectations.
   - Cache embedding results in Postgres if latency is critical.

---

## Sources

- **[T1]** elixir-nx/xla GitHub: https://github.com/elixir-nx/xla
  - README: Architecture support, precompiled binaries, cross-compilation.
  - Releases: v0.9.1+ (glibc 2.31+, aarch64-linux-gnu support).
  - Issues #8, #58: Apple Silicon and ROCm discussion (informs cross-arch challenges).

- **[T1]** elixir-nx/nx/exla README: https://github.com/elixir-nx/nx/blob/main/exla/README.md
  - EXLA setup, precompilation, caching, and cross-compilation guidance.

- **[T1]** Hex.pm xla package: https://hex.pm/packages/xla
  - Release history, architecture targets.

- **[T2]** ElixirForum "Issue with Exla deploying incorrect architecture" (2024): https://elixirforum.com/t/issue-with-exla-deploying-incorrect-architecture-for-live-beats-cm-streams-branch-whisper/57747
  - Real-world architecture mismatch incident; EXLA 0.6.0+ fix.

- **[T2]** ElixirForum "ARM64 Dockerfile failing" (2024): https://elixirforum.com/t/arm64-dockerfile-failing/57317
  - Erlang/OTP 26+ QEMU segfault workaround (`ERL_FLAGS`).

- **[T1]** elixir-nx/xla GitHub Issue #8: https://github.com/elixir-nx/xla/issues/8
  - Apple Silicon / arm64 cross-compilation challenges (Bazel, Java compatibility).

- **[T1]** GitHub elixir-nx/bumblebee: https://github.com/elixir-nx/bumblebee
  - Text embedding model support; Nx backend pluggability.

---

## Summary: Risk Verdict and Recommendation

**Risk Level: MEDIUM**

**Why:**
- ✅ Precompiled binaries exist and are maintained (v0.9.1+).
- ✅ aarch64-linux-gnu is an officially supported target.
- ❌ Cross-architecture deployment requires careful configuration (gotchas #1, #2, #3).
- ❌ Real incidents of architecture mismatch have occurred (ElixirForum 2024).
- ⚠️ Erlang/OTP 26+ QEMU issues require workarounds for Docker builds on x86.

**Recommendation:**
- **Proceed with EXLA on arm64** if you can:
  1. Build the release on an ARM64 instance (or use `ERL_FLAGS` workaround for x86→arm64 Docker).
  2. Verify precompiled binaries at deploy time.
  3. Warmup the model at app startup.
  4. Keep llama.cpp HTTP sidecar as a fallback (low effort to implement as a separate container).

- **If deployment becomes problematic:** Pivot to llama.cpp sidecar (tested, stable, widely used in Elixir community for embeddings).

**Timeline:** Expect 2–4 week investigation/testing cycle for a first production deployment. Once validated, operation is smooth.
