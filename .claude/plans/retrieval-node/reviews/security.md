# Security Review: Phases 8+9 (retrieval-node, uncommitted diff vs 7a77ca2)

## Executive Summary
No injection/authz-bypass found in the new code. LAN-only/no-auth v1 scope is accepted
by design and not re-flagged. Two real findings worth fixing before the auth/TLS
fast-follow ships; one design gap worth a decision; one low-severity info-leak note.

## Findings

### 1. `git grep` subprocess is not guaranteed to die when the budget/timeout closes the Port
- **Severity**: WARNING
- **Location**: `lib/retrieval_node/ingest/git_mirror.ex:300-323` (`grep_receive/4`), also applies to the existing `run_git/4` timeout path (`:263`)
- **Issue**: `Port.close/1` (and killing the owning `Task` via `brutal_kill`) closes the Erlang-side port but does **not** send a signal to the spawned OS process. `git grep` only notices via `SIGPIPE`/`EPIPE` the next time it tries to write to the now-closed pipe — which may not happen promptly if it's mid-tree-walk without a pending write (e.g. scanning many non-matching files, or already past `-m 100` on the current file). The module doc's claim that killing the task "clos[es] the port and terminat[es] git" isn't guaranteed. Since the budget-triggered early stop (`grep_max_bytes`/`grep_max_matches`, hit routinely, not just on rare timeout) is new, unauthenticated LAN behavior, a caller can cheaply spawn `git grep` processes over large mirrors that keep running/consuming CPU after the RPC has already returned truncated results — a real, repeatable resource-exhaustion vector, not just an edge case.
- **Fix**: Capture the OS pid (`Port.info(port, :os_pid)`) right after `Port.open` and explicitly kill it (`System.cmd("kill", [...])` or a wrapper like `muontrap`/`erlexec`) whenever the port is closed early, in both `grep_receive/4` and the `run_git/4` timeout branch.

### 2. Backup dump file inherits default (world/group-readable) permissions
- **Severity**: WARNING
- **Location**: `deploy/backup_postgres.sh:31`
- **Issue**: `pg_dump --no-owner "$db_name" | gzip >"$dest"` creates `$dest` with the process umask (no explicit `chmod`), typically `644` under a default `postgres`-user umask — world-readable to any local account on the host. The dump contains the full `pending_chunks` staging table, which stores `raw_content` **pre-scrub** (redaction happens when chunks are written, not on the raw ingest row) — so a backup taken mid-pipeline can persist plaintext secrets on disk, readable by any local user, for the whole retention window (14 days by default).
- **Fix**: `umask 077` at the top of the script (or `chmod 600 "$dest"` right after the pipe), and set `backup_dir` to `0700`.

### 3. `RETRIEVAL_NODE_DB_PASSWORD` passed as literal SQL text on the `psql -c` command line
- **Severity**: WARNING
- **Location**: `deploy/setup_postgres.sh:66` (`run_as_postgres -c "CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}';"`)
- **Issue**: The password is interpolated straight into the SQL string passed via `-c`, so it's visible in `/proc/<pid>/cmdline` / `ps aux` output to any local user for the process's lifetime, and would appear in shell debug (`set -x`) or process-accounting logs if either is ever enabled. It's a one-time setup script (not attacker-facing over the network), so this is a WARNING not a BLOCKER, but it's an easy fix.
- **Fix**: Feed the `CREATE ROLE` statement via stdin (`printf ... | run_as_postgres -f -`) instead of embedding it in `-c`'s argv.

### 4. `/healthz` error detail may over-share internals to any LAN caller
- **Severity**: SUGGESTION
- **Location**: `lib/retrieval_node_web/controllers/health_controller.ex:110-119` (`db_check/0`), `:70-79` (`grammar_cache_check/0`)
- **Issue**: `db_check` returns `inspect(reason)` (a raw Postgrex/DBConnection error struct) and the rescue branch returns `Exception.message(e)` verbatim in the JSON response; `grammar_cache_check` echoes `Grammars.missing()` (filesystem paths) directly. Route is unauthenticated by design (accepted), but detail granularity is higher than a readiness probe needs — fine for LAN-only, but should be trimmed (or gated behind the eventual auth) before internet exposure, since it can leak absolute paths / driver internals to any caller. No DoS amplification found: every gate is either a cheap in-memory check or a single `SELECT 1` — no expensive work per request.
- **Fix**: Reduce to a fixed reason atom (e.g. `%{reason: "db_unreachable"}`) once this route is reachable off-LAN; not urgent for the current slice.

## Clean / verified (no findings)
- `git_mirror.ex` `grep/3`: arg-list-only `Port.open({:spawn_executable, ...})`, `safe_ref/1` (no leading `-`) + `-e`-guarded pattern preserved as the flag-injection defense (git grep has no `--end-of-options`); `Path.safe_relative` on slug/show-path; transport allowlist (`safe_url/1`, blocks `ext::`) all carried through the Port rewrite unchanged. `complete_records/1` correctly drops a partial trailing record on budget cutoff (no parser desync/corruption). Per-chunk reads are pipe-buffer-bounded, so the budget check can only be overrun by roughly one OS pipe buffer, not unbounded.
- `scrubber.ex` `sobelow_skip` comments (`Traversal.FileModule`, `CI.System`) match reality: paths are self-generated random names inside an exclusively-created `0700` temp dir, `System.cmd` is arg-list-only behind a `find_executable` guard. `.sobelow-conf`'s `Config.HTTPS` ignore is the documented, in-scope LAN-only decision.
- `pending_chunks.ex`/`chunking.ex` `binary_content?/1`: routing guard only (keeps invalid-UTF-8 out of a `text` column); doesn't weaken the scrub/secrets guarantee since redaction runs on chunk content downstream regardless.
- `upsert_chunks.ex` `to_enum/2`: resolves staged enum strings via `Ecto.Enum.mappings/2` (a closed allowlist keyed off the schema) rather than `String.to_atom`/`to_existing_atom` — correctly atom-exhaustion-resistant and rejects unknown values instead of silently mapping them.
- `rn.seed.ex`: `--git-url` is an operator-supplied CLI arg (not remote input) and still passes through `GitMirror.safe_url/1`'s transport allowlist before any `git clone` — no bypass.
- `retrieval_node.service`: hardening present (`NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`), secrets kept in a separate `EnvironmentFile` (documented `root:root 0600`) rather than the world-readable unit file. `rel/env.sh.eex` echoes no secrets.

## Tools to Recommend
- `mix sobelow --exit low` (matches `.sobelow-conf`'s configured threshold)
- `mix deps.audit`
- `mix hex.audit`
