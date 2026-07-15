---
module: "Ingest.GitMirror"
date: "2026-07-15"
problem_type: otp_issue
component: genserver
symptoms:
  - "Orphaned `git grep` OS processes consuming CPU after the Elixir caller already returned truncated results"
  - "No error anywhere — the BEAM side looks finished; only ps/pgrep shows the leftover process still walking a large tree"
root_cause: "Port.close/1 (and killing the port-owning process) only detaches the BEAM from the port — it does NOT signal the external OS process, which exits only on SIGPIPE at its NEXT stdout write; a process mid-scan with nothing to write yet can run arbitrarily long, and an early-stop path that fires routinely (output budgets) turns that into a repeatable resource leak"
severity: high
tags: [port, os-process, sigpipe, orphan-process, resource-exhaustion, system-cmd, streaming]
elixir_version: "1.20.2"
---

# `Port.close/1` doesn't kill the external process — SIGKILL the os_pid on early close

## Symptoms

After budget-truncated `git grep` calls (streaming Port with byte/match
budgets + early `Port.close`), `pgrep` showed the git processes still alive
and burning CPU on large mirrors — long after the RPC returned. Unauthenticated
LAN callers could trigger this repeatedly: cheap resource exhaustion.

## Investigation

1. Assumed (wrongly) that closing the port terminates the child — it only
   closes the pipe. The child dies on **SIGPIPE at its next write**; a scan
   phase that produces no output for a long time never hits one.
2. Same gap existed on the timeout path (`Task.shutdown(:brutal_kill)` of the
   port owner) — and the old `System.cmd`-based path had no OS pid at all.

## Root Cause

BEAM ports are pipes, not process supervisors. `Port.close/1` guarantees
nothing about the external process's lifetime. Any early-abandonment path
(budgets, timeouts, caller crash) needs an explicit OS-level kill.

## Solution

Capture the pid at open; kill explicitly on every early-termination path;
never kill after a normal `exit_status`:

```elixir
port = Port.open({:spawn_executable, git}, [:binary, :exit_status, args: args])
{:os_pid, os_pid} = Port.info(port, :os_pid)

# budget stop / timeout paths:
Port.close(port)
kill_os_pid(os_pid)

defp kill_os_pid(nil), do: :ok
defp kill_os_pid(os_pid) do
  # pid-reuse pedantry: killing immediately after deciding to stop is fine
  System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
  :ok
rescue
  _ -> :ok   # already dead / kill missing — nothing to do
end
```

For a timeout enforced by an *outer* process (`Task.yield` + `brutal_kill`),
the port owner sends `{:git_os_pid, ref, os_pid}` to the caller right after
opening, so the timeout branch can kill after `Task.shutdown` (a fresh
`make_ref` per call prevents cross-talk between concurrent git ops).

### Files Changed

- `lib/retrieval_node/ingest/git_mirror.ex` — shared `open_git_port/2`, kill on budget + timeout paths
- `test/retrieval_node/ingest/git_mirror_test.exs` — asserts the process is gone within 1s (poll, not instant)

## Prevention

- Every streaming-Port consumer with an early-stop path must pair
  `Port.close/1` with an explicit `os_pid` kill; grep for `Port.close` in
  review.
- Tests for "process cleanup" should poll `pgrep` with a short deadline
  ("eventually gone"), never assert instant death.
- `System.cmd/3` hides the os_pid entirely — if you might ever need to kill
  the child, use a raw Port from the start.
