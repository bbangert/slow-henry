# Security Audit: retrieval_node (Phase 0–2)

## Executive Summary
Clean. No BLOCKERS. The primary concern — raw SQL in `hybrid_query.ex` — is
**not** an injection surface: every user/query-derived value is a bound
parameter; the only string interpolation is a compile-time integer module
attribute. Schemas correctly avoid storing plaintext secrets. A few low-severity
hardening SUGGESTIONS below.

## Primary Questions — Answered

### 1. Raw SQL injection surface — NONE (confirmed)
`lib/retrieval_node/search/hybrid_query.ex:46-85`. The `@sql` heredoc contains
exactly one interpolation: `#{@candidate_pool}` (line 58, 67), which is a
compile-time module attribute = integer literal `200`. All user/query-influenced
values are bound Postgrex parameters passed via `Repo.query!/2` (lines 98-108):
- `$1` embedding → `Pgvector.new(embedding)` (bound)
- `$2` text_query → bound, consumed only by `websearch_to_tsquery`
- `$3` rrf_k (compile-time), `$4` top_k (bound)
- `$5` source_id, `$6` repo, `$7` lang → bound
No user value reaches the SQL via interpolation. **Confirmed safe.**

### 2. websearch_to_tsquery on untrusted text — SAFE (confirmed)
`websearch_to_tsquery` is Postgres' web-search-syntax parser, designed for raw
end-user input; it never raises on malformed input (unlike `to_tsquery`) and the
argument is a bound parameter, not concatenated SQL. Correct choice.

### 3. secret_findings — no plaintext (confirmed)
`secret_finding.ex` / migration `...120006`: stores `match_hash` (sha256) only.
No field holds the raw secret. `file_reference` is a path, `span` a jsonb
offset map. **Confirmed.** See SUGGESTION S1 on `span`.

### 4. Chunk back-link projection — no content leak (confirmed)
`hybrid_query.ex` SELECT (lines 78-84) never selects `content`; `row_to_result`
and `search.ex` `to_hit/1` (lines 44-56) project only `id, source_type, repo,
lang, context_breadcrumb, metadata`. Hot path is content-free by design.
**Confirmed.**

### 5. Secrets in config — dev/test defaults only (low sev)
`config/dev.exs:30` and `config/test.exs:22` carry hardcoded `secret_key_base`;
dev/test DB use `postgres/postgres`. These are standard Phoenix-generated
non-production defaults. Prod loads `SECRET_KEY_BASE` + `DATABASE_URL` from env
in `runtime.exs` (raises if missing). Acceptable; noted.

## Findings

### S1 — SUGGESTION: guarantee `span` stores offsets, not matched text
`secret_finding.ex:19` `span` is a free `:map`. Schema is correct today, but the
(later-phase) writer must store character offsets only — never the matched
substring — or the "never stores the raw secret" invariant leaks via jsonb.
Add a test asserting `span` contains no secret material.

### S2 — SUGGESTION: `sources.config` may hold live credentials, unredacted
`source.ex:19` `config` (jsonb) is the natural home for git tokens / Jira API
keys / Drive creds. It is a plain `:map` with no `redact: true` and no
`:filter_parameters` coverage. If a `Source` struct or its changeset is ever
logged/inspected, credentials leak. Recommend: mark sensitive keys redacted,
configure `config :phoenix, :filter_parameters`, and consider encryption-at-rest
(e.g. Cloak) before Phase where ingestion creds land.

### S3 — SUGGESTION: `raw_content` in `pending_chunks` transiently holds secrets
Migration `...120007`: `raw_content`/`chunk_content` hold pre-scrub file content
that may contain secrets until UpsertChunks deletes the row. By design, but
ensure failed/abandoned rows are reaped (no indefinitely-retained plaintext) and
that these columns are excluded from any debug logging.

### S4 — SUGGESTION: bound `top_k` / validate it's a small positive integer
`hybrid_query.ex:96` `top_k` flows to `LIMIT $4` unbounded. Not injectable (bound
param), but a caller-supplied huge value is a mild resource/DoS lever once search
is exposed via MCP. Clamp to a sane max (e.g. ≤100).

## Posture
Checked: SQL injection (parameterized, safe), XSS (no templates/`raw/1`),
atom exhaustion (no `String.to_atom` on user input; `String.to_integer` only on
operator env vars), changeset coverage (all writes via changesets), secrets
(prod via env). No `binary_to_term`, no path traversal, no unsafe deserialization
in scope. All clean.

## Tools to Recommend (run manually — no Bash access here)
- `mix sobelow --exit medium` (sobelow already in deps)
- `mix deps.audit` / `mix hex.audit`
- `mix credo --strict`
