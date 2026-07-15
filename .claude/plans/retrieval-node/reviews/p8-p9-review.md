# Review: Phases 8+9 — supervision/build/deploy + first-slice validation

**Date**: 2026-07-15 · **Scope**: uncommitted working tree vs `main` @ `7a77ca2` (56 files)
**Panel**: elixir-reviewer, security-analyzer, testing-reviewer, deployment-validator,
requirements-verifier (consolidated in `../summaries/review-consolidated.md`; raw
per-agent output in `elixir.md`, `security.md`, `testing.md`, `deploy.md`, `requirements.md`)

## VERDICT: REQUIRES CHANGES

Two deploy blockers (both cheap to fix, both would break the *first arm64 deploy*,
neither affects the running dev slice). Code quality otherwise strong: zero blockers
in application code; the security panel explicitly verified the Port rewrite, scrubber
skips, and enum fix clean. Requirements: **0 UNMET** (4 PARTIALs are documented
scope deferrals, not misses).

## Requirements Coverage — 11 MET · 4 PARTIAL · 0 UNMET · 1 UNCLEAR

Source: plan Phases 8–9. All MET items verified at file:line against actual code
(supervision order, ELF gate over all 3 artifacts, the 4 healthz gates, Port
streaming, all 3 live-corpus bug fixes). PARTIAL/UNCLEAR detail:

- **#11 verify (arm64 legs)** — scripts exist + wired; on-device run is explicit
  DEFERRED-MANUAL (no arm64 hardware here).
- **#12 seed corpus** — git leg MET; Jira/Drive env mapping implemented but not
  run (credentials absent, correctly deferred).
- **#14 benchmark harness** — all metrics + PASS/FAIL/SKIPPED reporting implemented;
  only 15/50–100 starter queries; 384-vs-768 delta is an always-SKIP truncation-
  stability proxy (real delta needs a corpus re-embed at 768).
- **#15 definition of done (UNCLEAR sub-claim)** — the live LAN/MCP proof rests on
  session evidence (`mcp_*.raw` captures), not on anything a static diff can show;
  Jira/Drive incremental rounds deferred with #12.

## BLOCKERs (2 — both deploy artifacts)

1. **Migrations have no working runtime entrypoint.** `deploy/README.md:21` and
   `deploy/setup_postgres.sh:80-81` instruct
   `bin/retrieval_node eval "RetrievalNode.Release.migrate()"`, but no
   `RetrievalNode.Release` module exists; `scripts/deploy.sh` never migrates.
   `/healthz`'s DB gate is `SELECT 1`, which passes on an empty database → first
   deploy boots "healthy" with no schema and no `vector` extension.
   **Fix**: add standard `lib/retrieval_node/release.ex`
   (`Ecto.Migrator.with_repo`-based `migrate/0`), invoke it as an explicit step in
   `deploy.sh` before the healthz poll.

2. **`ExecStop` depends on Erlang distribution, which is disabled by design.**
   `deploy/retrieval_node.service:22` runs `bin/retrieval_node stop` (RPC over
   distribution) while `rel/env.sh.eex:10` sets `RELEASE_DISTRIBUTION=none` — every
   stop/restart logs a failed ExecStop before systemd falls back to SIGTERM.
   **Fix**: delete `ExecStop=` (SIGTERM is the correct mechanism) and pin
   `TimeoutStopSec` (see W7).

## WARNINGs (9)

1. **Orphaned `git grep` processes on early Port close** —
   `lib/retrieval_node/ingest/git_mirror.ex:300-323` (+ `run_git/4` timeout path).
   `Port.close/1` doesn't signal the OS process; git dies only on its next write
   (SIGPIPE). The budget stop fires *routinely* on unauthenticated LAN input →
   cheap repeatable CPU exhaustion on large mirrors.
   **Fix**: capture `Port.info(port, :os_pid)` after open; kill explicitly on early
   close (both paths).
2. **Backup dumps world-readable with PRE-SCRUB content** —
   `deploy/backup_postgres.sh:31`. No `chmod`/`umask`; `pending_chunks.raw_content`
   is pre-redaction, so a mid-ingest backup can persist plaintext secrets at 0644
   for the 14-day retention window. **Fix**: `umask 077` + 0700 backup dir.
3. **DB password in `psql -c` argv** — `deploy/setup_postgres.sh:66`; visible in
   `/proc/*/cmdline` during setup. **Fix**: feed SQL via stdin.
4. **Async hazard: `serving_test.exs` mutates the global readiness persistent_term
   under `async: true`** — races `health_controller_test.exs` (which is carefully
   `async: false` for the same key). **Fix**: `async: false` on ServingTest.
5. **Async hazard: `tree_sitter_impl_test.exs:101-118` terminates/restarts the real
   app-tree `ChunkTaskSupervisor` under `async: true`**. **Fix**: `async: false`.
6. **No test for `Embedding.Supervisor`'s load-bearing `:rest_for_one` semantics**
   (Serving crash must restart Warmer → reset+rewarm). The moduledoc's core claim
   is unverified and will bit-rot silently. **Fix**: kill-child test asserting
   Warmer restarts and `ready?` flips false.
7. **No explicit `TimeoutStopSec`** — `deploy/retrieval_node.service` relies on the
   distro default. **Fix**: `TimeoutStopSec=60` (pairs with Blocker 2's fix).
8. **First backup run fails on fresh host** — `BACKUP_DIR=/var/backups/retrieval_node`
   not creatable by `User=postgres`; nothing pre-creates it.
   **Fix**: `install -d -o postgres -m 0750` in setup_postgres.sh.
9. **`runtime.exs:66-75` advertises `https://…:443` while serving plain HTTP** —
   phx.new boilerplate; wrong URLs if url helpers are ever used.
   **Fix**: match reality (`scheme: "http", port: port`) or comment as decorative.

## SUGGESTIONs

- **Demoted from WARNING with empirical evidence** — `rn.seed.ex` boot-pattern
  consistency: reviewer flagged `Mix.Task.run("app.start")` (vs siblings'
  `app.config` + `ensure_all_started`) with `:eaddrinuse` + hang risk. The task was
  executed 4× this session, twice *while a dev server ran*, and exited cleanly every
  time (bare `app.start` does not serve the endpoint). Aligning with `rn.bench`'s
  pattern is still worthwhile hygiene; revisit the `System.halt` question only if
  switching to `ensure_all_started`.
- `/healthz` returns raw `inspect(reason)`/paths to any LAN caller — trim to fixed
  reason atoms before internet exposure (pairs with the auth fast-follow). No DoS
  amplification found (all gates cheap).
- `test/support/fake_grammar_pack.ex` mirrors the grammar-pack seam by naming
  convention only — consider a `@behaviour` contract like the Chunking/Embedding seams.
- Perf nit: `count_newlines/1` allocates `:binary.matches` list to count (bounded by
  the 1MB grep budget — low impact). `warmup/0`'s rescue branch untested directly.

## Verified clean (evidence, brief)

Security: all GitMirror injection defenses survive the Port rewrite (arg-list,
`safe_ref`, `-e` guard, `safe_relative`, transport allowlist incl. `ext::` block);
scrubber `sobelow_skip` comments match reality; `Config.HTTPS` ignore = documented
LAN-only decision; `to_enum/2` atom-exhaustion-resistant; `rn.seed --git-url` cannot
bypass the URL allowlist; unit-file secrets handling correct.
Deploy: ELF gates (pre+post release), grammar-cache overlay path consistency,
healthz/deploy.sh port consistency, hardening avoids breaking NIF/EXLA dlopen,
PGDG arm64 + idempotent setup, non-root service user.

## Fix pass outcomes (2026-07-15, applied on user approval)

- **Blocker 1 FIXED**: `lib/retrieval_node/release.ex` created (Ecto.Migrator-based
  migrate/0 + rollback/2); `deploy.sh` migrates after symlink flip and aborts BEFORE
  restart on failure (old release keeps running). Bonus catch: `bin/... eval`
  bypasses systemd's EnvironmentFile, so deploy.sh now sources the env file first.
- **Blocker 2 FIXED**: ExecStop removed (comment explains SIGTERM is correct);
  `TimeoutStopSec=60` added (also closes W7).
- **W1 FIXED**: `Port.info(:os_pid)` captured for grep AND all run_git calls
  (System.cmd path replaced with a Port); SIGKILL on budget-stop + timeout paths,
  never on normal exit; test asserts the OS process is gone within 1s.
- **W2/W3/W8 FIXED**: umask 077 + 0700 backup dir; CREATE ROLE via psql stdin
  vars (password out of argv); setup pre-creates BACKUP_DIR owned by postgres.
- **W4/W5 FIXED**: both test modules async: false with rationale comments.
- **W6 FIXED**: `Embedding.Supervisor.init/1` accepts children/name opts (prod
  default unchanged); new supervisor_test kills a fake Serving and proves
  rest_for_one restarts Warmer and resets ready? to false.
- **W9 FIXED**: runtime.exs url now scheme http + real port, commented.
- **Suggestions**: deferred (all cosmetic/hygiene or gated on the auth fast-follow).
- **Extra fix found during final verification**: `seed_repo_with_many_matches` test
  helper flaked ~1-in-3 full runs — `System.unique_integer` repeats across BEAM
  runs and the dir leaked, so later runs could hit a byte-identical leftover repo
  ("nothing to commit"). Now OS-pid-qualified + rm_rf'd + on_exit-cleaned.
  (Was misattributed to concurrent-agent interference during the fix pass.)

**Post-fix gates**: 180 tests ×3 consecutive full runs, credo --strict clean,
format clean, `mix sobelow --exit` clean. Verdict after fixes: **PASS** (the two
PARTIAL requirements — query-set size, Matryoshka real delta — remain documented
scope items, not regressions).

## Recommended fix order

1. Blockers 1–2 + W7 (one small deploy-artifact pass; required before first deploy)
2. W1 (os_pid kill — the only application-code warning with a security dimension)
3. W2/W3/W8 (deploy-script hardening pass)
4. W4/W5/W6 (test-suite pass)
5. W9 + suggestions (cosmetic/hygiene)
