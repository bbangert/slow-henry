# retrieval_node: Build & Deploy Pipeline Design

**Date:** 2026-07-14
**Target:** Self-hosted Ubuntu/Debian arm64 (glibc) production server; x86-64 local dev only.
**Applies findings from:** `exla-aarch64.md`, `treesitter-arm64.md`, `nif-isolation-design.md`.

Fixed decision (not re-litigated here): **never cross-build**. Every production
artifact — the Rustler NIF, the EXLA/XLA `.so`, the release tarball — is built
by a process actually running on aarch64. x86-64 is dev-only.

---

## 1. Build Pipeline (arm64), Step by Step

Runs entirely on an arm64 box (CI runner or persistent build box — see §2).
All steps run as the deploy user, not root.

1. **Checkout** the tagged commit/ref to build.
2. **Toolchain setup**: `erlef/setup-beam` (or asdf/mise) installs the pinned
   OTP + Elixir versions; `rustup` installs Rust with target
   `aarch64-unknown-linux-gnu` added (host == target here, no `cross` needed
   since we're natively on arm64 — this is the whole point of not
   cross-building).
3. **`mix deps.get --only prod`** — resolves hex + git deps.
4. **`mix compile` (`MIX_ENV=prod`)** — this is where `tree_sitter_language_pack`'s
   Rustler NIF actually compiles: since no `aarch64-unknown-linux-gnu`
   precompiled hex binary exists for this package, Rustler falls back to
   `cargo build` on-device, producing a native `.so` for the box's own arch.
   Expect 5–15 min, 2–4 GB RAM for the link step (per treesitter-arm64.md).
   Also set `XLA_TARGET_PLATFORM=aarch64-linux-gnu` in the build env so EXLA's
   `xla` dep deterministically downloads the aarch64-linux-gnu-cpu precompiled
   archive instead of guessing from `:erlang.system_info` at compile time.
5. **Grammar prefetch** — run a dedicated Mix task (e.g.
   `mix run -e "TreeSitterLanguagePack.prefetch(allowlist())"`) rather than
   relying on first-request runtime download. This must run on THIS arm64 box
   so the cached grammar `.so`s are aarch64-compiled, not reused from an x86
   dev cache. Language allowlist (fixed list, not `:all`, to bound build time
   and cache size):
   - `:elixir`, `:heex`, `:eex` (the app's own stack — required)
   - `:python`, `:javascript`, `:typescript`, `:go`, `:rust`, `:ruby`, `:java`
     (typical polyglot team repo coverage)
   Cache lands in `$XDG_CACHE_HOME` (pin this env var explicitly to a known
   path, e.g. `/var/cache/retrieval_node/tree_sitter/`, rather than trusting
   the build user's default `~/.cache`, since the release-running systemd
   service will use a different `$HOME`/user than the build step — the cache
   dir must be readable by whichever user/path the release actually looks up
   at runtime, or copied into a release overlay).
6. **Verification step (fail the build here, not later)** — confirm every
   arch-sensitive artifact is actually aarch64 ELF before packaging:
   ```bash
   file _build/prod/lib/tree_sitter_language_pack/priv/native/*.so
   file _build/prod/lib/exla/priv/*.so 2>/dev/null || file $(mix run -e 'IO.puts(EXLA.Client.get_supported_platforms() |> inspect())')
   file _build/prod/rel/*/erts-*/bin/beam.smp 2>/dev/null  # after release, see step 7
   ```
   Expected on every line: `ELF 64-bit LSB ... ARM aarch64`. Any hit of
   `x86-64` or `x86_64` here means a cached artifact leaked in (e.g. a stale
   `_build/` or `deps/` directory carried over from a dev machine, or a Docker
   layer built for the wrong `--platform`) — **hard-fail the pipeline**, do
   not ship. This is the single check that catches the "segfault in prod"
   failure mode called out in exla-aarch64.md (the real ElixirForum incident).
   Also assert glibc compatibility on the build box itself once:
   `ldd --version | head -1` → must be ≥ 2.31 (xla v0.9.1+ requirement).
7. **`MIX_ENV=prod mix release`** — packages BEAM + compiled NIFs + EXLA `.so`
   + prefetched grammar cache (via a release overlay/`Release.steps/1` copying
   the cache dir into `priv/` so it ships inside the tarball rather than
   depending on the target host having the same cache path — see §4) into a
   single tarball. Re-run the `file` check against the packaged
   `_build/prod/rel/retrieval_node/` tree as a final gate (artifacts inside
   the release must match the ones checked in step 6 — this catches a release
   step accidentally re-fetching/re-linking anything).
8. **Publish artifact** (CI artifact store, or scp to a release staging dir)
   tagged with version + git sha + arch, e.g.
   `retrieval_node-1.4.0-abc1234-aarch64.tar.gz`.

## 2. CI/CD Structure

**Assumption (explicit):** the team does not currently have a native arm64
GitHub-hosted runner entitlement. As of mid-2026, GitHub does offer hosted
arm64 Linux runners on paid plans (`ubuntu-24.04-arm` family), but availability
varies by org plan tier — treat this as **unconfirmed for this org** and
design for the fallback:

- **Preferred if available:** GitHub-hosted arm64 runner
  (`runs-on: ubuntu-24.04-arm` or equivalent) or a hosted arm64 runner service
  (Ubicloud arm64 runners are a known third-party option). Zero extra infra to
  maintain; treat exactly like any other GH Actions job.
- **Fallback (assume this by default):** a **self-hosted arm64 runner** —
  register a persistent arm64 Linux box (could be the same class of hardware
  as prod, or a Graviton/other ARM cloud VM) as a GitHub Actions self-hosted
  runner, or skip GH Actions entirely and run the build pipeline as a script
  triggered by CI on merge/tag, executed via SSH against a dedicated arm64
  **build box** (separate from the production server — building competes for
  CPU/RAM with the tree-sitter Rust link step and EXLA download, and you don't
  want a bad build's leftover processes near prod).
- Either way: build box and production server must match — same glibc/distro
  major version, since EXLA's glibc ≥2.31 requirement and general ELF/libc
  ABI compatibility both depend on the two being close cousins (ideally
  identical Ubuntu/Debian release).
- **Never** attempt Docker/QEMU cross-build from an x86 CI runner as the
  primary path — it's viable per exla-aarch64.md §3B with `ERL_FLAGS` fixups,
  but the tree-sitter NIF cross-compile risk plus double-fixing two unrelated
  QEMU workarounds is not worth it when a real arm64 runner is an option, and
  the fixed context for this design has already ruled it out.
- Pipeline stages: `test` (can run on x86 CI — regular `mix test`, no arch
  sensitivity for unit tests that don't hit real NIFs, or on arm64 if you want
  full fidelity) → `build-arm64` (steps 1–8 above, arm64 only) →
  `deploy` (copy tarball to prod host, run the systemd swap — see §3).

## 3. systemd Unit

```ini
[Unit]
Description=retrieval_node
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=exec
User=retrieval_node
Group=retrieval_node
WorkingDirectory=/opt/retrieval_node/current
ExecStart=/opt/retrieval_node/current/bin/retrieval_node start
ExecStop=/opt/retrieval_node/current/bin/retrieval_node stop
Restart=on-failure
RestartSec=2
# bound restart storms without masking a real crash loop
StartLimitIntervalSec=300
StartLimitBurst=10

Environment=RELEASE_COOKIE=<generated-secret, not in git>
Environment=DATABASE_URL=ecto://retrieval_node:***@localhost/retrieval_node_prod
Environment=SECRET_KEY_BASE=<generated>
Environment=PHX_HOST=retrieval.internal.example.com
Environment=PORT=4000
Environment=XDG_CACHE_HOME=/var/lib/retrieval_node/cache
EnvironmentFile=-/etc/retrieval_node/env   # Jira/Drive OAuth client id/secret, etc — kept out of the unit file itself, 0600, root:retrieval_node

[Install]
WantedBy=multi-user.target
```

Notes:
- `Type=exec` (not `simple`) so systemd tracks the actual BEAM PID accurately
  for restart/stop semantics.
- `Restart=on-failure` is deliberate, not merely "best practice boilerplate":
  nif-isolation-design.md documents that a tree-sitter C segfault kills the
  whole BEAM VM outright, bypassing any in-VM supervisor. The peer-node
  isolation design (parser work farmed out to supervised peer nodes) contains
  *most* crashes without taking down the main VM — but systemd
  `Restart=on-failure` is the last-resort backstop for the case a peer-node
  crash somehow still takes the main VM down, or an unrelated fault occurs.
  `RestartSec=2` + `StartLimitBurst=10`/`StartLimitIntervalSec=300` avoids a
  fast crash-loop from hammering Postgres connections or filling disk with
  logs, while still recovering automatically from an isolated crash.
- Secrets (`SECRET_KEY_BASE`, `DATABASE_URL` password, OAuth client
  secrets for Jira/Drive) live in `EnvironmentFile=-/etc/retrieval_node/env`
  (the leading `-` makes it non-fatal if absent, for local testing of the
  unit) rather than inline in the unit file, which is world-readable via
  `systemctl cat`.
- `RELEASE_COOKIE` only matters if the app ever needs distributed Erlang
  (which it does, per the peer-node NIF isolation design — main node +
  parser peer nodes on the same host need to speak distribution to each
  other). Generate it once, store alongside the other secrets, keep it
  identical across restarts (a new cookie on each deploy would break peer
  node reattachment if peer nodes ever persist independently — they don't
  here since they're spawned in-process at boot, but keep it stable anyway
  since it's cheap and avoids surprises).

**Disk layout:**
- `/opt/retrieval_node/releases/<version>/` — extracted release tarballs,
  one directory per deployed version.
- `/opt/retrieval_node/current` — symlink to the active release dir, flipped
  atomically on deploy (`ln -sfn`), then `systemctl restart retrieval_node`.
- `/var/lib/retrieval_node/cache/tree_sitter/` — grammar `.so` cache
  (`XDG_CACHE_HOME`), persisted across deploys since it's expensive to
  rebuild; also embedded as a fallback copy inside the release itself (§1
  step 5) so a fresh host or wiped cache dir doesn't require rebuilding on
  first boot.
- `/var/lib/postgresql/<version>/main/` — standard OS-package Postgres data
  dir; untouched by the app's deploy process. `pgvector` extension installed
  once via `apt install postgresql-<version>-pgvector` (or built from source
  if not packaged for the distro release) and enabled per-database with
  `CREATE EXTENSION vector;` in a migration, not at OS-install time.
- `/var/lib/retrieval_node/git-mirrors/` — bare git mirrors used for repo
  ingestion, owned by the `retrieval_node` service user, separate from both
  the release dir (which gets wiped/replaced on deploy) and Postgres's data
  dir.

## 4. Application Startup Sequence

Within `RetrievalNode.Application.start/2`, ordered so failures surface loud
and early rather than degrading silently:

1. **Grammar-cache presence check**, before the endpoint starts accepting
   traffic: read the same allowlist used at build time (§1 step 5) and
   confirm each language's compiled grammar `.so` exists in
   `XDG_CACHE_HOME` (or the release's embedded fallback copy — copy it into
   place at boot if the external cache dir is empty, e.g. fresh host). If any
   allowlisted language is missing, **log at `:error` and refuse to start
   cleanly** (crash the boot, let systemd's `Restart=on-failure` retry loop
   surface it, or better: `System.halt(1)` with a clear message) rather than
   silently falling back to first-request on-demand compilation in
   production — a 5–15 minute on-device Rust compile happening in the middle
   of serving live traffic is exactly the failure mode this design exists to
   prevent. Log line shape: `"[boot] tree-sitter grammar cache verified: 10/10 languages present"` vs. `"[boot] MISSING grammar cache for :go — was prefetch() run at build time? refusing to start"`.
2. **EXLA/Nx backend sanity check**: log `Nx.default_backend()` and the
   result of `EXLA.Client.get_supported_platforms()`; assert the active
   backend is EXLA (not a silent fallback to `Nx.BinaryBackend`, which would
   be 10–100x slower and mask a broken EXLA install). Fail boot on mismatch.
3. **Start the Nx.Serving embedding model child** in the supervision tree
   (e.g. `RetrievalNode.Embedding.Serving`, a `Supervisor.child_spec` wrapping
   `Bumblebee.Text.embedding/3`'s serving process). Immediately after the
   serving process reports ready (in its own `start_link`/`init`, or a
   `Task` run from the parent supervisor right after `start_link` returns —
   either works, but doing it *inside* the child's own startup keeps the
   warmup coupled to the thing it's warming, so a warmup crash correctly
   fails that child's start rather than looking like an unrelated boot
   problem), run one dummy inference with production input shape (e.g. a
   short representative string) through `Bumblebee.run/2` (or
   `Nx.Serving.run/2` depending on API surface) to force JIT compilation
   before the endpoint accepts real traffic. This is the mitigation for the
   documented 10–30s first-request JIT stall (bge-small class model on
   modern arm64 CPU, per exla-aarch64.md).
4. **Peer-node parser pool** starts (per nif-isolation-design.md's
   `RetrievalNode.Chunking.NodePool`), each peer confirming its own tree-sitter
   NIF loads cleanly against the now-verified grammar cache.
5. Only after 1–4 succeed does the Phoenix endpoint (or its health-check
   route specifically) report ready — wire this into a `/healthz` route that
   checks these startup flags (stored in `:persistent_term` or an Agent set
   during boot) rather than just "process is up", so a load balancer / uptime
   check reflects real readiness, not just BEAM-is-alive.

## 5. x86-64 Dev Path — Deltas from Prod

Dev is unremarkable by design; only call out what's *different*:

- **No arm64 verification step.** `tree_sitter_language_pack`'s Rustler NIF
  and EXLA's `xla` dep both have first-class x86_64-linux-gnu precompiled
  binaries, so `mix deps.get && mix compile` "just works" without the
  `file`-command ELF check — that check exists specifically to catch
  arch-mismatch risk, which doesn't apply when host arch == the only arch
  a dev machine will ever run.
- **`mix phx.server`** directly for iteration, not `mix release` — no need
  for a release tarball, systemd unit, or the release-overlay cache-copy
  trick; `TreeSitterLanguagePack.prefetch/0` can still be called once
  locally (or left to lazy runtime download) since dev iteration tolerates
  an occasional first-use download/compile pause that would be unacceptable
  in prod.
- **Grammar cache** uses the default `~/.cache/tree-sitter-language-pack/`
  (no need to pin `XDG_CACHE_HOME` to a fixed path, since there's no
  release-packaging step that needs a predictable path to bundle from).
- **Skip the CI arm64 runner entirely** for local dev loops — dev's `mix
  test`/`mix compile` runs on whatever x86-64 laptop/devcontainer the
  developer has; the arm64-specific pipeline (§1–§2) only fires on
  merge/tag for the actual deployable artifact.
- **EXLA backend**: on x86-64 dev, `Nx.default_backend()` should still
  resolve to EXLA (prebuilt x86_64 binaries are equally available), so the
  same startup sanity check (§4 step 2) can and should still run in dev —
  it's cheap and catches local environment breakage early, it just isn't
  the arch-mismatch risk prod cares about.
- **No systemd unit / no `/opt/retrieval_node` disk layout** — dev runs
  from the checked-out working tree with `.env`/`config/dev.exs` secrets,
  not `EnvironmentFile`-sourced production secrets.

---

## Summary of Key Risk Callouts Carried Forward

- Cross-building is the failure mode both source docs independently flag as
  causing real prod segfaults/incompatible-architecture errors — this design
  structurally avoids it by requiring arm64-native build infra (§2).
- The `file`-command ELF verification (§1 step 6, repeated at the release
  layer in step 7) is the single cheapest gate that catches a leaked
  x86 artifact before it reaches prod.
- Grammar prefetch (§1 step 5) plus a hard startup check (§4 step 1) turns a
  silent "falls back to slow runtime compile" degradation into a loud boot
  failure, consistent with the project's general design principle of
  surfacing broken setup rather than degrading quietly.
- systemd `Restart=on-failure` (§3) is a deliberate backstop for the
  documented tree-sitter C-level segfault risk that bypasses OTP supervision
  entirely, layered underneath (not instead of) the peer-node isolation
  design.
