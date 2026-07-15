---
module: "Ingest.PendingChunks"
date: "2026-07-15"
problem_type: database_issue
component: ecto_query
symptoms:
  - "Postgrex.Error ERROR 22021 (character_not_in_repertoire) invalid byte sequence for encoding UTF8: 0x89 during insert_all into a text column"
  - "RepoSync Oban job fails every attempt (retryable → discarded) as soon as the repo contains any binary file (e.g. priv/static/favicon.ico)"
root_cause: "RepoSync staged raw file bytes into pending_chunks.raw_content (a Postgres text column) with no binary-content guard at the staging seam — the existing guard lived downstream in the chunking stage, which never runs because the INSERT crashes first; Postgres text rejects ANY invalid UTF-8, not just NUL bytes"
severity: high
tags: [binary-content, utf8, staging-table, insert-all, guard-placement, ingest-pipeline]
elixir_version: "1.20.2"
---

# Binary files crash the staging INSERT — guard sat downstream of the failure

## Symptoms

Seeding a real git repo through the ingest pipeline: `RepoSync` failed
repeatedly with `Postgrex.Error 22021 ... invalid byte sequence for encoding
"UTF8": 0x89` (the PNG/ICO magic byte). The repo's `priv/static/favicon.ico`
was being staged verbatim into `pending_chunks.raw_content`.

## Investigation

1. **The pipeline HAD a binary guard** — Phase 4's chunking pre-flight rejects
   binary content (`:binary_content`)… but it runs in the `ChunkFiles` stage,
   *after* staging. The whole-job INSERT crashed before any guard executed.
2. **NUL-byte detection is not enough**: the downstream guard checked for NUL
   bytes; Postgres `text` rejects **any** invalid UTF-8 (favicon's `0x89`
   contains no NUL). The staging-side check must be the strict union.

## Root Cause

Guard placement: content-validity checks must sit at the **staging choke
point** (where bytes first meet the database), not only at the consumer.
A stubbed test suite never catches this — only a real repo with a real
binary file does.

## Solution

Single source of truth, enforced at the shared insert path all three sync
workers (git/Jira/Drive) go through:

```elixir
# RetrievalNode.Chunking
def binary_content?(content),
  do: String.contains?(content, <<0>>) or not String.valid?(content)

# RetrievalNode.Ingest.PendingChunks.insert_raw_all/1
{binary_rows, text_rows} = Enum.split_with(rows, &Chunking.binary_content?(&1.raw_content))
# binary_rows: logged + skipped — no pending_chunk row, no ChunkFiles job
```

The downstream chunking guard now delegates to the same function.

### Files Changed

- `lib/retrieval_node/chunking.ex` — public `binary_content?/1`
- `lib/retrieval_node/ingest/pending_chunks.ex` — guard at `insert_raw_all/1`
- `lib/retrieval_node/chunking/tree_sitter_impl.ex` — delegates to the shared check
- tests: binary + invalid-UTF-8-without-NUL repos complete the sync, skip the file

## Prevention

- When a validity rule exists at a consumer, ask where the data FIRST crosses
  a persistence boundary — that's where the guard belongs (consumers keep a
  defensive copy).
- For Postgres `text` columns: validate `String.valid?/1`, not just NUL-free.
- E2E-test ingest pipelines against a *real* messy corpus at least once; the
  stub suite can't represent what real repos contain.

## Related

- `.claude/solutions/phoenix-issues/vector-zero-dimensions-missing-output-pool-embedding-20260715.md` — found in the same first-live-ingest session
