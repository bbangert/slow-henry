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

Fields present on a single matcher are **AND'd together**. At least one of
the three fields must be set — an empty matcher would match every chunk in
the corpus and silently inflate every nDCG score, so `Bench.Runner` raises
loudly at load time if it sees one.

**Why match on metadata, not chunk ids**: chunk ids are regenerated on every
re-ingest (`Chunk.id` is `autogenerate: true`), but `repo`/`path`/breadcrumb
are stable identifiers a chunker preserves across re-ingest as long as the
source file/symbol itself hasn't moved. A query set built on ids would need
re-labeling after every corpus rebuild; one built on these matchers doesn't.

**Why `path_prefix` carries the starter set, not `breadcrumb_substring`**:
this repo's own source is Elixir, and Elixir isn't yet in
`TreeSitterImpl.allowed_languages/0` (fast-follow item — see
`design-build.md`), so it falls through to `HeuristicImpl`, whose chunks all
carry an **empty** symbol trail (`breadcrumb: ""`, per
`Chunking.Breadcrumb.build/2`) — `context_breadcrumb` for an Elixir chunk is
just its file path, same information `path_prefix` already captures more
precisely. `breadcrumb_substring` becomes useful once a source in a
tree-sitter-covered language (Python/JS/Go/Rust/Ruby/Java) or a Docs source
(breadcrumb = doc title) is seeded — its matchers should prefer
`breadcrumb_substring` for symbol-level precision.

## Example: multi-file matcher

A query whose answer spans several files ORs multiple matchers:

```json
{"query": "how is the embedding serving supervised", "relevant": [{"path_prefix": "lib/retrieval_node/embedding/supervisor.ex"}, {"path_prefix": "lib/retrieval_node/embedding/serving.ex"}], "note": "..."}
```
