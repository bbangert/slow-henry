# Review — Retrieval Node, Phase 4 (chunking subsystem)

**Verdict: PASS WITH WARNINGS** · 0 true blockers · 5 MET / 1 PARTIAL requirements
Branch `feat/retrieval-node-chunking` vs `main`. Agents: elixir-reviewer, otp-advisor,
security-analyzer, testing-reviewer, requirements-verifier.

## Requirements Coverage
5 MET · 1 PARTIAL · 0 UNMET. PARTIAL: the plan checkbox says "31 tests NIF-free" but that's
the *whole-suite* count; Phase 4 itself adds ~19 NIF-free + 2 integration. Wording fix.

## Downgraded from BLOCKER
- **elixir-reviewer flagged `ChunkTaskSupervisor` not in the supervision tree as a blocker.**
  It's the **explicitly-deferred Phase 8 item** (the plan's Phase 8 supervision tree already lists
  `{Task.Supervisor, ChunkTaskSupervisor}`), same pattern as Phase 3's Serving. otp-advisor
  correctly reclassified it a **sequencing WARNING**: `async_nolink` would raise `:noproc` in the
  caller (which `guarded/1` can't catch) — but nothing calls `TreeSitterImpl` in production until
  the Phase 6 worker + Phase 8 tree land. Action: ensure Phase 8 lands before any runtime caller;
  add a code comment noting the dependency.

## ✅ Fixes applied (post-review)
All actionable findings addressed; verified (35 tests + 11 integration, credo/dialyzer/format clean):
1. **Unbounded chunk** — added a `@hard_max_bytes` boundary in the heuristic that fires regardless
   of brace balance (+ runaway/soft-cap/CRLF tests). 2. **O(n²)** — `named_children/1` rewritten as
   an O(n) TreeCursor walk (integration tests confirm extraction unchanged). 3. guard reorder
   (allowlist first), `binary_part` end>start guard, breadcrumb newline sanitize (+ test),
   shutdown-race + ChunkTaskSupervisor-dependency comments. 4. CRLF + `@max_chunk_bytes` boundary
   tests; strengthened the guarded-liveness assertion. Plan test-count wording corrected; Phase 6
   fallback-flow note recorded (skip heuristic on `:too_large`/`:binary_content`).

## Findings worth acting on (ALL ADDRESSED — see above)

- **[elixir + security · HIGH CONFIDENCE] Heuristic can emit an unbounded chunk.** `brace_delta`
  counts `{`/`}` inside string/comment literals, so an unmatched brace in a literal drives `balance`
  positive forever; since a boundary needs `balance <= 0`, the soft `@max_chunk_bytes` cap never
  fires and the rest of the file becomes one chunk. Separately, a 2 MB single line (minified/base64)
  is one giant chunk regardless. **Fix:** a hard byte-cap boundary that fires irrespective of brace
  balance, and split a single line exceeding it. `heuristic_impl.ex`.
- **[elixir · warn] `named_children/1` is O(n²).** Indexed `TS.node_named_child(node, i)` rescans
  from the first child each call. The dep's `TreeCursor` (`goto_first_child`/`goto_next_sibling`)
  is O(1)-amortized. Matters for files with many top-level defs. **Fix:** cursor-based sibling walk.
- **[elixir + security · suggestion] Reorder guards:** check the O(1) language allowlist before the
  O(n) binary-content scan, so an unsupported language skips the up-to-2 MB scan. `tree_sitter_impl.ex`.
- **[security · suggestion] `binary_part` negative length** (end < start) is silently accepted and
  reads backwards. tree-sitter offsets are always end≥start, so theoretical — add an assertion.
- **[security · suggestion] Breadcrumb identifiers are untrusted** — could contain `\n`/`>`/HTML
  (spoofing, or XSS if ever rendered unescaped). Sanitize newlines now; rely on HEEx escaping downstream.
- **[otp · suggestion] Add a comment** noting the `shutdown(:brutal_kill)` race is handled by `Task`
  internals, so a future maintainer doesn't "fix" a non-bug.
- **[testing · warn] Test gaps:** no `@max_chunk_bytes` boundary test; no CRLF test (`\r` leaks into
  chunk `text`); the `Process.alive?(self())` assertion is transitively-useful but vacuous on its own.

## Deferred / noted (later phase)
- **[security · warn] Heuristic fallback flow:** on tree-sitter `:too_large`/`:binary_content`, the
  Phase 6 `ChunkFiles` worker must NOT re-run the heuristic (it has no size guard) — fall back only on
  `:chunk_timeout`/`:chunk_crashed`/`:unsupported_language`. Decide in Phase 6. (The hard-cap fix above
  also bounds the heuristic if it ever does see a big input.)
- Breadcrumb HTML escaping — MCP/rendering phase.

## Clean (verified)
`guarded/1` mechanics **race-free by construction** (otp traced Task source; all 5 return shapes
covered, monitor/alias cleanup sound, `:brutal_kill` correct); `binary_part` is BEAM bounds-checked
and unicode-safe; `String.contains?(bin, <<0>>)` byte-safe; guards check size first; behaviour/
dispatcher and `Breadcrumb` concat clean; `:integration` exclusion + `capture_log` wiring correct.
