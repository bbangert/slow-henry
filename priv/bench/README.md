# Benchmark query set

`queries.jsonl` is the labeled query set for `mix rn.bench` (see
`RetrievalNode.Bench.Runner` and the `mix rn.bench` task moduledoc for the
harness itself, and `.claude/plans/retrieval-node/research/embedding-model.md`
for the protocol this implements).

## Target size

**50-100 labeled queries** is the target set size per the benchmark protocol
(15 code-based, 15 Jira/issue, 20 Docs, roughly). `queries.jsonl` currently
ships **15 starter queries**, all code-based and all pointed at this repo's
own source (`slow-henry` is the seed corpus for Phase 9's thin-corpus
validation — one git repo, no Jira/Drive sources are ingested yet). Extend it
once Jira/Drive sources exist in the seed corpus; correct measurement
(the harness runs and reports honestly) matters more than the query count for
this task — the numbers get tuned later.

## Format

One JSON object per line (JSONL — no comments allowed inline, hence this
file):

```json
{"query": "<natural-language question>", "relevant": [<matcher>, ...], "note": "<optional human context>"}
```

* `query` (required, string) — the text passed to `Search.hybrid_search/2`.
* `relevant` (required, list of matchers, min length 1) — chunks considered
  relevant for this query. Matchers are **OR'd together** (a chunk counts as
  relevant if it satisfies any one matcher in the list).
* `note` (optional, string) — why this query/matcher pair was chosen; not used
  by the harness, purely for a future human editing the query set.

### Matcher shape

A matcher is a JSON object with any (non-empty) combination of:

* `"repo"` — exact match against `Chunk.repo`.
* `"path_prefix"` — prefix match against `Chunk.metadata["path"]` (the
  git-relative file path; only set for `:git_repo` chunks).
* `"breadcrumb_substring"` — case-insensitive substring match against
  `Chunk.context_breadcrumb`.
* `"content_substring"` — case-**sensitive** literal substring of
  `Chunk.content` (LIKE metacharacters are not special). Use it for
  answer-level queries: relevance should mean "this chunk contains the
  answer", not "this chunk is in the right file". Pick a short, single-line
  literal so it can't be split across two chunks.

Fields present on a single matcher are **AND'd together**. At least one of
the four fields must be set — an empty matcher would match every chunk in
the corpus and silently inflate every nDCG score, so `Bench.Runner` raises
loudly at load time if it sees one.

**Why match on metadata, not chunk ids**: chunk ids are regenerated on every
re-ingest (`Chunk.id` is `autogenerate: true`), but `repo`/`path`/breadcrumb
are stable identifiers a chunker preserves across re-ingest as long as the
source file/symbol itself hasn't moved. A query set built on ids would need
re-labeling after every corpus rebuild; one built on these matchers doesn't.

**Why `path_prefix` carries the starter set**: the starter set is this repo's
own Elixir source, which is AST-chunked with symbol breadcrumbs, but its queries
are file-level questions, so the file path is the precise identifier.
`breadcrumb_substring` is for symbol-level precision (e.g. a specific
function/class trail, or a Docs source where the breadcrumb is the doc title).
For top-level (gap) chunks — code between definitions — the breadcrumb is just
the file path, so use `path_prefix` for those.

## Top-level content queries

`toplevel_queries.jsonl` is a second, separate set of 16 queries whose answers
live in top-level code outside any function/class: Python constants
(`const.py`), `__all__`, module-level registries and `PLATFORM_SCHEMA`s,
TypeScript top-level `const`s, type unions and `customElements.define`
registrations, Go top-level `var`s. Before top-level (gap) chunks existed these
were not indexed (files with no definitions produced zero chunks), so it is the
measure for that feature. It targets the multi-repo seed corpus (`core`,
`frontend`, `cli`, `supervisor`, `esphome`), with `repo` equal to the source
name and a `content_substring` on every matcher so only chunks containing the
answer count as relevant, and is unresolved (excluded from aggregates) on a corpus without them.

    mix rn.bench --queries priv/bench/toplevel_queries.jsonl

`mix rn.bench` is safe to run against a database shared with a running dev
node: it boots with no Oban queues/plugins/peer and no ingest boot-resume.

## Example: multi-file matcher

A query whose answer spans several files ORs multiple matchers:

```json
{"query": "how is the embedding serving supervised", "relevant": [{"path_prefix": "lib/retrieval_node/embedding/supervisor.ex"}, {"path_prefix": "lib/retrieval_node/embedding/serving.ex"}], "note": "..."}
```
