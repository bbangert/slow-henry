# Elixir Review: Phases 8+9 (supervision tree, /healthz, deploy pipeline, seed/bench tasks, git-grep Port streaming, 3 bug fixes)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 4

## Warnings

1. **lib/mix/tasks/rn.seed.ex:99** — `boot/0` calls `Mix.Task.run("app.start")`, which
   is exactly the pattern the mix-tasks convention forbids ("never `Mix.Task.run("app.start")`
   — boots the FULL tree: endpoint port, Oban consuming"). The task's own comment says
   "This task only needs Repo + Oban's insert path" and it already disables Oban
   queues/plugins via config — but `app.start` still boots `RetrievalNodeWeb.Endpoint`
   (binding the configured HTTP port) and the Anubis MCP server (`mcp_server_start?`
   defaults `true`), neither of which this task touches. Compare to `rn.bench.ex` and
   `rn.grammars.prefetch.ex` in the same diff, which correctly use
   `Mix.Task.run("app.config")` + `Application.ensure_all_started/1` (bench) or just
   `app.config` (grammars.prefetch). Running `mix rn.seed` while a dev server (or
   another `rn.seed`/`rn.bench` invocation) already has the port bound will crash on
   `:eaddrinuse`. Fix: `Mix.Task.run("app.config")` +
   `Application.ensure_all_started(:retrieval_node)`, matching `rn.bench`.

2. **lib/mix/tasks/rn.seed.ex** — Unlike `rn.bench.ex` (which explicitly calls
   `System.halt(0)` with a comment explaining that `ensure_all_started` brings up the
   *entire* supervision tree including the Endpoint/Oban/embedding sub-tree, "none of
   which has a reason to keep running once the report is printed... Without an
   explicit halt, `mix rn.bench` would hang"), `rn.seed.run/1` never halts after
   `seed/1`/`print_status/1` return. Given point 1, `rn.seed` boots the identical
   full tree via `app.start` and has the same "hangs after completing" characteristic
   that the bench task's own doc explicitly calls out — but no `System.halt(0)` is
   present. If bench's stated rationale is accurate, `mix rn.seed` will not return
   control to the shell after seeding, contrary to its own moduledoc's "then rerun
   `mix rn.seed`" workflow implying a normal exit. UNVERIFIED: whether the default
   Mix task runner halts the VM regardless of running supervisors — worth confirming
   interactively; if confirmed, add the same `System.halt(0)` rn.bench uses (after
   fixing #1 so the two tasks boot consistently via `ensure_all_started`).

## Suggestions

1. **lib/retrieval_node/ingest/git_mirror.ex:331** — `count_newlines/1` builds the
   full match list via `:binary.matches(chunk, "\n")` just to call `length/1` on it,
   allocating an intermediate list of `{pos, len}` tuples per chunk purely to count
   newlines. Minor — `grep_max_bytes` already bounds this to ~1MB/repo — but a
   manual byte-scan or `:binary.matches |> length` replaced with counting via
   pattern `Enum.count` would avoid the intermediate list if streaming chunk sizes
   ever grow.

2. **lib/retrieval_node/embedding/nx_serving_impl.ex:73-90** — `matryoshka/1`'s two
   guard clauses (`tuple_size(shape) != 1`, `dims < @dimensions`) both raise with
   similar messages pointing at the same misconfiguration; fine as multi-clause
   pattern matching, just noting there's no guard for the degenerate `dims == 0`
   case distinct from "too few dims" (falls into the second clause correctly since
   `0 < 384`), so no actual gap — just flagging the boundary was checked.

## Notes (persistent from prior-phase reviews)

None found still present in this diff's changed files — `lib/retrieval_node/ingest/scrubber.ex`,
`jira.ex`, and `drive.ex` appear otherwise unchanged from the Phase 5/6 versions already
covered by `p5-elixir.md`/`p6a-elixir.md`/`p6b-elixir.md`.

## Confirmed correct (per WHY-CONTEXT, not re-flagged)

- `Embedding.Supervisor`/`Warmer`/`Serving` rest_for_one wiring matches the stated
  design exactly: `Serving.reset_ready/0` runs synchronously in `Warmer.init/1`
  before `handle_continue` fires the slow warmup — no stale-`true` window is
  reachable between a `Serving` crash-restart and the next warmup completing.
- `HealthController` gates correctly report `:skipped` (counted as passing, not
  `:error`) when a subsystem is config-disabled, per the stated skip rule; `db_check/0`
  correctly wraps `Repo.query/1` in `rescue` so a dead pool degrades the gate rather
  than 500ing the whole `/healthz` request.
- `GitMirror.grep/3`'s Port-streaming budget check happens between chunks (not
  mid-chunk) as documented, and `complete_records/1` correctly trims to the last
  full `\n`-terminated record before parsing — no truncated-record corruption on
  the truncated path.
- `UpsertChunks.to_enum/2` using `Ecto.Enum.mappings/2` instead of
  `String.to_existing_atom/1` correctly avoids the load-order atom-interning bug
  described in the WHY-CONTEXT bug-fix list; the allowlist-then-raise fallback is
  the correct fail-loud shape for an unrecognized dump value.
