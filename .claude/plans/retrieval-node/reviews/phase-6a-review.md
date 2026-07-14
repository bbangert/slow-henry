# Review — Retrieval Node, Phase 6a (ingest plumbing)

**Verdict: REQUIRES CHANGES** · 1 verified security BLOCKER · 10/10 requirements MET
Branch `feat/retrieval-node-ingest-plumbing` vs `main`. Agents: security-analyzer, ecto-schema-designer,
elixir-reviewer, testing-reviewer, requirements-verifier.

## Requirements Coverage
10 MET · 0 UNMET. Oban config, PendingChunk schema (matches Phase 1 migration), PendingChunks context,
GitMirror + safety guards all present; namespace confirmed `Ingest`; cron/tree correctly deferred.

## ✅ Fixes applied (post-review)
Blocker + warnings addressed; verified (18 ingest tests / 76 total, credo/dialyzer/format clean):
- **BLOCKER (git option injection)**: `safe_ref/1` validates every ref/sha (`\A[0-9A-Za-z][…]`,
  rejects leading dash + `:`) → `{:error, :invalid_ref}`; `--end-of-options` added to
  rev-parse(`--verify`)/ls-tree/diff/show/clone (grep relies on validation). Verified the exploit
  refs (`--output=`, `--open-files-in-pager=`) no longer create files.
- **url transport allowlist** (`safe_url/1`) blocks `ext::sh`/`-`-prefixed clone URLs.
- **`show` size guard** (`cat-file -s` → `:file_too_large` over 5MB) bounds memory.
- **`parse_grep`**: `-I` skips binary files + `Integer.parse` fall-through (no more raise).
- **`insert_raw_all` → bulk `insert_all`** (one round-trip); dropped the self-qualified alias +
  redundant `:status` cast.
- Tests added: ref/url-injection rejection, the fetch branch, `set_embeddings` value round-trip,
  atomic NOT-NULL abort.

## 🔴 BLOCKER — git option injection (security-analyzer, verified) — FIXED
The argument-list `System.cmd` closes *shell* injection, but **git parses `-`-prefixed operands as
flags**, and `ref`/`old_sha`/`new_sha` are passed as bare args with **zero validation** and no
`--end-of-options` guard. Per Phase 7, these come from **untrusted MCP callers** (`grep`/`get_file`).
- **`grep/3` → RCE**: `git grep --open-files-in-pager=<cmd>` *executes* a command; `ref` is unguarded.
- **`show/3` → arbitrary file write**: `ref` is prefixed into `"#{ref}:#{safe}"`, so
  `ref = "--output=/etc/cron.d/x"` sidesteps the path guard (`git show --output=`).
- **`changed_files/3` → arbitrary write** via `git diff --output=`.
**Fix:** validate every ref/sha (`\A[0-9A-Za-z][0-9A-Za-z._/-]*\z`, reject `:`) → `{:error, :invalid_ref}`,
AND add `--end-of-options` before each ref/sha operand. Add ref-injection-rejection tests.

## Warnings
- **[security] clone `url` transport injection** — `git clone <url>` honors `ext::sh -c …` / `--upload-pack`
  (RCE). `url` is operator-config (from Sources), so lower, but add `--end-of-options` before it and an
  `https://`/`git@`/`file://` transport allowlist. `ensure_mirror`.
- **[security] Unbounded `System.cmd` output** — `show`/`grep` buffer the whole result in memory; a huge
  file → OOM. Cap output size (or note the upstream 2MB bound doesn't apply to `show`).
- **[elixir + testing] `parse_grep` can raise** — `git grep -n` without `-I` emits `HEAD:Binary file <p>
  matches` for binary hits; a colon in the path makes the 3-way split "succeed" and `String.to_integer`
  raises, escaping the "always `{:error}`" contract. **Fix:** add `-I` to grep + `Integer.parse` fall-through.
- **[ecto] Per-row insert loops** — `insert_raw_all`/`write_chunks`/`set_embeddings` do N `Repo.insert`/
  `update_all` round-trips in a transaction; design-oban calls for bulk `insert_all`. Real perf gap once
  `*Sync` batches get large. **Fix:** `insert_all` for the raw bulk insert at least.
- **[testing] `ensure_mirror` fetch branch untested** — setup only hits the clone path; the incremental-sync
  `git fetch --prune` path (the primary steady-state operation) has zero coverage.
- **[testing] `set_embeddings` checks length, not values** — a transposed/garbled write passes silently.
- **[elixir] `delete_by_ids` calls `PendingChunks.by_ids`** fully-qualified from inside the module — use
  `by_ids/1` unqualified (drop the self-alias).

## Suggestions
- `raw_changeset` casts `:status` then overwrites via `put_change` — drop `:status` from the cast allowlist.
- `content_hash` (dedup/change-detection) has no index or query helper — confirm where dedup happens when
  `*Sync` lands (staging vs permanent `chunks`).
- `@type t :: %__MODULE__{}` is a harmless no-op; the `[0, 1]` ok_codes literal could be named.

## Confirmed safe / good (verified)
`Path.safe_relative` correctly rejects absolute + `..` on the **path** side (the escape is the ref side);
`-e` guards the grep `pattern`; Oban config well-formed (Pruner/Lifeline keys checked vs Oban source,
`testing: :manual` deep-merges, pool_size math checks out); `Pgvector.new` in `update_all set:` is
**required** (dump is a passthrough) — correct as written; `PendingChunk` schema matches the migration.
