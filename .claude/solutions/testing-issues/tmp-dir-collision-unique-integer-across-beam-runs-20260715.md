---
module: "Ingest.GitMirrorTest"
date: "2026-07-15"
problem_type: test_failure
component: testing
symptoms:
  - "Intermittent (~1 in 3 full runs) MatchError: {\"On branch main\\nnothing to commit, working tree clean\\n\", 1} from a git-commit test helper"
  - "Never fails when the single test file is run in isolation right after; easily misattributed to 'environmental' interference"
root_cause: "test fixture dir named with System.unique_integer([:positive]), which restarts and REPEATS across BEAM runs; the helper never cleaned the dir up, so a later `mix test` run could land on a leftover repo from a previous run containing byte-identical files — git add stages nothing and git commit exits 1 with 'nothing to commit'"
severity: medium
tags: [flaky-test, unique-integer, tmp-dir, fixtures, cross-run-collision, git]
elixir_version: "1.20.2"
---

# Flaky fixture: `System.unique_integer` repeats across BEAM runs

## Symptoms

`seed_repo_with_many_matches` intermittently failed `{out, 0} = System.cmd(...)`
with git reporting `nothing to commit, working tree clean` — right after
writing 30 files into a "fresh" repo. Roughly 1 in 3 *full-suite* runs; scoped
reruns usually green. An earlier debugging pass wrongly blamed concurrent
agents sharing the machine.

## Investigation

1. Reproduced with nothing else running → not environmental.
2. The failing helper built its path as
   `Path.join(System.tmp_dir!(), "gm-biggrep-#{System.unique_integer([:positive])}")`
   and **never removed it**. `System.unique_integer/1` is unique only within
   one BEAM instance — values repeat across runs. A later run hitting a reused
   integer found the previous run's repo (already committed, byte-identical
   content) → `git add .` staged nothing → commit exit 1.
3. The sibling fixture with the same naming didn't flake — because it *did*
   `File.rm_rf` in `on_exit`, so nothing persisted to collide with.

## Root Cause

`System.unique_integer/1` guarantees uniqueness per VM instance, not across
invocations. Uncleaned tmp fixtures + per-VM-unique names = cross-run
collisions that look random (they depend on how many integers other code
consumed before the helper ran).

## Solution

```elixir
src =
  Path.join(
    System.tmp_dir!(),
    "gm-biggrep-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.rm_rf!(src)          # defensive: clear any leftover
File.mkdir_p!(src)
on_exit(fn -> File.rm_rf(src) end)
```

OS pid + unique_integer is collision-proof across runs; the `rm_rf!` +
`on_exit` make leftovers impossible either way.

### Files Changed

- `test/retrieval_node/ingest/git_mirror_test.exs` — helper path + cleanup

## Prevention

- Tmp fixture names need an ACROSS-RUN unique component (`System.pid()`), not
  just `unique_integer`; and every fixture that creates disk state registers
  `on_exit` cleanup.
- A flake that "reproduces only in full runs" and involves tmp paths: check
  for cross-run leftovers before blaming concurrency.
- Verify suspected "environmental" flakes on a quiet machine before accepting
  that explanation — this one was misattributed once.
