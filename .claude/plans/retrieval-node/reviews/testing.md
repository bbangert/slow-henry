# Testing Review: Phases 8+9 test files (retrieval-node)

## Summary
Overall solid: budget/truncation, binary-skip, and Oban reconciliation tests
are well built with hand-computed assertions and real-git fixtures. Two real
async hazards and one supervision-behavior coverage gap stand out.

## Iron Law Violations
- ASYNC BY DEFAULT: `serving_test.exs` (async: true) and
  `tree_sitter_impl_test.exs`'s "without the supervisor" describe block
  (module is async: true) both mutate process-global/application-supervision
  state — see Warnings below.

## Issues Found

### Critical
None. No new public context function, `handle_event`, Oban worker, or
LiveView route in this diff lacks coverage.

### Warnings

- **Global-state async hazard: `Serving` readiness flag mutated under
  `async: true`.** `test/retrieval_node/embedding/serving_test.exs` (`use
  ExUnit.Case, async: true`) directly pokes the process-wide
  `:persistent_term.put({Serving, :ready?}, ...)` key and calls
  `Serving.reset_ready/0`. `test/.../health_controller_test.exs` deliberately
  uses `async: false` *because* it touches this same global flag — but since
  it's a different module marked async, ExUnit can schedule it concurrently
  with the async `ServingTest`, racing the same key. Mark `ServingTest`
  `async: false` too (cheap; it's 2 tests), or route it through a
  dependency-injected name instead of the shared `{Serving, :ready?}` key.

- **`tree_sitter_impl_test.exs` "guarded/1 without the supervisor running"**
  (lines 101–118) terminates and restarts the real, application-tree-owned
  `RetrievalNode.ChunkTaskSupervisor` child of `RetrievalNode.Supervisor`
  while the module is `async: true`. The comment argues no other test in
  *this file* depends on it concurrently, but `async: true` means other test
  *files* can run concurrently too — any future test exercising
  `TreeSitterImpl.guarded/1` from a different module (chunking_impl is
  HeuristicImpl in `:test` today, but that's incidental, not enforced) would
  flake against this one tearing down the shared supervisor mid-run. This
  test mutates global supervision state and should be `async: false`, not
  rely on "nothing else needs it today."

- **No test coverage for `RetrievalNode.Embedding.Supervisor`'s
  `:rest_for_one` restart semantics.** `lib/retrieval_node/embedding/supervisor.ex`'s
  moduledoc spends several paragraphs justifying `:rest_for_one` over
  `:one_for_one` as load-bearing (a `Serving` crash must restart `Warmer` to
  re-run warmup and reset readiness). Nothing in the diff (`serving_test.exs`
  only exercises `Warmer.init/1` standalone via `start_supervised!(Warmer)`,
  never under the real `Supervisor`) verifies that killing `Serving` actually
  restarts `Warmer` and flips `ready?` back to `false`. This is exactly the
  kind of OTP-topology claim that silently bit-rots if the strategy is ever
  changed back to `:one_for_one`; a small test starting `Supervisor` with
  fake config, killing the `Serving` child, and asserting `Warmer` restarts
  would close the gap.

### Suggestions

- `test/support/fake_grammar_pack.ex` has no `@behaviour` and there is no
  `@callback` contract defined for the `:grammar_pack_mod` seam (unlike
  `Chunking`'s and `Embedding`'s own `@callback`-defined impl seams — both
  confirmed present in `lib/retrieval_node/chunking.ex` and
  `lib/retrieval_node/embedding.ex`, which this module's own moduledoc says
  it mirrors). `TreeSitterLanguagePack` is an external hex dep so wrapping it
  is correct, but the fake currently only agrees with the real module by
  naming convention, not a compiler-checked contract. Consider a thin
  `@behaviour` (e.g. `RetrievalNode.Chunking.GrammarPack`) implemented by
  both `FakeGrammarPack` and a real adapter module, per the stated pattern.

- `Serving.warmup/0`'s `rescue` branch (malformed-embedding exception, as
  opposed to the `:exit`/`:noproc` path already exercised via
  `ServingTest`'s `Warmer.init/1` test) has no direct test. Low priority
  since `nx_serving_impl_test.exs` covers the underlying `matryoshka/1` raise
  conditions, but nothing confirms `warmup/0` itself catches and logs rather
  than propagating a raised error.
