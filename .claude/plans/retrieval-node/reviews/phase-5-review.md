# Review — Retrieval Node, Phase 5 (secrets scrubbing)

**Verdict: REQUIRES CHANGES** · security-critical module · 13/0 MET/UNMET requirements
Branch `feat/retrieval-node-scrubber` vs `main`. Agents: security-analyzer (lead), elixir-reviewer,
testing-reviewer, requirements-verifier.

## Requirements Coverage
13 MET · 0 UNMET · 1 UNCLEAR (credo/dialyzer/format cleanliness — verified separately: clean).
All policy checkboxes + reconciliation #5 (corrected gitleaks semantics) backed by code. Pipeline
wiring (Scrubber inside ChunkFiles) is correctly Phase 6.

## ✅ Fixes applied (post-review)
All must-fix + warnings addressed; verified (22 scrubber tests / 58 total, credo/dialyzer/format clean):
- **Temp file**: `System.find_executable` guard (no write when gitleaks absent); when present, a
  private **0700** dir with an unguessable `strong_rand_bytes` name, created exclusively (`mkdir!`).
- **Log/telemetry leak**: dropped gitleaks stderr from errors; rescue logs exception type + stacktrace
  only (never the content-bearing message).
- **Duplicate-secret bug**: `parse_gitleaks_report` now emits a finding per `:binary.matches` occurrence.
- **Fail-closed**: `redaction_left_secret?/2` (public, detector-agnostic — checks each finding's match
  text, gitleaks types included) + direct tests of both outcomes.
- **Deterministic degrade**: `:gitleaks_cmd` configurable; the test forces a bogus binary. Size cap
  (`@max_scan_bytes`) → `{:cancel, :content_too_large}`.
- **Audit atomicity**: `record_findings` wrapped in `Repo.transaction`.
- Tests added: duplicate/overlap/UTF-8 redaction, cancel path, whole-row raw-secret check, size cap.

## Must-fix (ALL FIXED — see above)

- **[security · HIGH] Temp file leaks plaintext secrets.** `gitleaks_scan` writes content to
  `System.tmp_dir/scrub-<unique_integer>.txt` — a **guessable** name (not mkstemp → symlink pre-plant
  in shared /tmp) at **0644** (other local users can read the secrets while it exists). And the write
  happens *before* the `System.cmd`, so even here (gitleaks absent) every git scrub briefly writes
  secrets to /tmp. **Fix:** `System.find_executable` first — skip writing entirely when gitleaks is
  absent; when present, create the file 0600 with exclusive open.
- **[security · HIGH] Secrets can leak into logs/telemetry.** gitleaks' captured stderr `out` flows
  into `{:error, {:gitleaks_exit, code, out}}` → `Logger.warning(inspect(reason))` and
  `:telemetry.execute(..., %{reason: reason})`; and `Logger.error("... #{inspect(e)}")` can embed the
  content binary. Secrets in logs defeat the module's purpose. **Fix:** log the exit code + a generic
  message only; never the gitleaks output blob or content-bearing exception payloads.
- **[elixir · CRITICAL + security] `parse_gitleaks_report` first-occurrence bug.** `:binary.match`
  returns only the FIRST offset, so a secret appearing twice → both findings resolve to the same span,
  `merge_spans` collapses them, and **copies 2..N survive as plaintext** — violating "never index a
  plaintext secret." (Regex path is fine; gitleaks path only.) **Fix:** redact ALL occurrences of each
  reported secret (`:binary.matches`).
- **[elixir + security + testing] Fail-closed guard is detector-blind + untested.**
  `high_confidence_survives?` re-scans only the 7 built-in regexes, so a surviving gitleaks-only secret
  type wouldn't trip `{:cancel}`; and neither `{:cancel}` nor `{:error, :scrub_unavailable}` has any
  test. **Fix:** make the fail-closed check verify no finding's match text survives redaction
  (detector-agnostic) — this closes the gap AND makes `{:cancel}` reachable/testable; add tests.

## Warnings
- **[testing] Degrade test silently depends on ambient gitleaks absence** — on a CI image *with*
  gitleaks it takes a different path without failing loudly. **Fix:** make the gitleaks command
  configurable and force the degrade branch deterministically; `:integration`-tag any real-gitleaks test.
- **[elixir] `record_findings` isn't transactional** — a bad changeset mid-loop leaves a partial audit
  trail and raises (contradicting its `{:ok, count}` spec). Wrap in a transaction (atomic audit).
- **[elixir] rescue logs `inspect(e)` only** — no stacktrace, masks real bugs. Log `Exception.format/3`
  with `__STACKTRACE__` (but per the log-leak fix, NOT secret-bearing content).
- **[testing] raw-secret audit test is narrow** — asserts `match_hash` only; strengthen to a whole-row
  check that no field contains the raw secret (future-proofs new columns).

## Suggestions
- **[security] Content size cap** — PEM lazy `[\s\S]+?` is mild O(n²) on unterminated markers; jira/drive
  text has no upstream size guard (unlike the 2MB chunker cap). Cap scan input.
- **[testing] Missing cases:** duplicate secrets, overlapping/adjacent spans (merge_spans direct),
  start/end-of-content, empty content, UTF-8 multibyte byte-vs-codepoint offset. Highest value:
  duplicate + overlapping + UTF-8 (byte-offset core).
- Comment the `redact/2` iodata-reversal; `merge_spans` merges touching-but-non-overlapping spans (loses
  2nd type label, low impact).

## Confirmed safe (verified)
No shell injection (`System.cmd` fixed arg list, no shell); unknown `source_type`/non-binary → clean
FunctionClauseError crash (never a silent unscanned pass — fail-closed holds); audit schema has no raw
column (`match_hash` sha256 only); no exponential ReDoS; `redact/2` byte-math correct for non-duplicate
cases; `Regex.scan(return: :index)` whole-match head-destructure correct.
