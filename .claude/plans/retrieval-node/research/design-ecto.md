# Data Model: retrieval_node (hybrid retrieval / RAG service)

## Ash Framework Check

`mix.exs` does not exist yet (greenfield). No Ash dependency assumed. If Ash is
introduced later, this document's schema/changeset code does not apply to
`Ash.Resource` modules — migrations and raw-SQL query patterns here (esp. the
RRF query and pgvector index DDL) remain valid regardless of Ash vs plain Ecto.

## Domain Overview

Three heterogeneous sources (git repos, Jira issues, Drive docs) are chunked,
embedded, and made searchable through one hybrid (vector + FTS) query. The
MCP `semantic_search` tool needs to filter by `source` (which source config),
`repo` (which git repo, when applicable), and `lang` (file language). Those
three are the only fields queried by *every* request, so they are promoted to
real, indexed columns. Everything else that varies per source type (Jira key,
Drive doc URL, git ref/sha, symbol name, byte offsets) lives in a `jsonb
metadata` column — this is the flexible-back-link case jsonb is *for*
(sparse, schema-varying, not filtered in hot-path queries), not a substitute
for real associations.

## 1. One `chunks` table vs per-source tables

**Decision: one unified `chunks` table** with a `source_id` FK to a `sources`
table, a denormalized `source_type` enum, and a `metadata` jsonb column for
source-specific back-links.

Rationale:
- The RRF hybrid query must union-rank across all sources in a single
  ordered result set. A single table with one HNSW index and one GIN index
  makes this one query; per-source tables would require `UNION ALL` across
  three CTEs *per side* of the fusion (vector + fts), doubling query
  complexity and preventing a single HNSW graph from being searched (HNSW
  recall degrades when split across multiple smaller indexes queried
  separately then merged).
- `source_type` as a real column (not buried in jsonb) lets Postgres use a
  btree/partial index for the `source`/`repo`/`lang` filters without jsonb
  containment operators, which are slower and harder to index well for
  simple equality filters.
- `metadata` jsonb holds truly source-varying back-link fields: Jira key +
  issue type, Drive doc URL + revision id, git ref/sha + byte range. These
  are never used to *filter* search (only to *display* result provenance),
  so jsonb's lack of a rigid schema is a feature, not a liability. This is
  the jsonb-for-flexible-non-hot-path-data pattern, not Rails-style
  polymorphic association abuse — there is still one real FK (`source_id`)
  with real referential integrity, not a `commentable_type/commentable_id`
  pair.
- A `sources` table (not just an enum) is needed anyway to track
  allow/deny + per-source sync watermarks, so `source_id` is "free."

## 2. `sources` table

Tracks every configured source (a git repo, a Jira project, a Drive folder),
its allow/deny status, and points sync-state at it 1:1.

**Fields**:
| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | :binary_id | PK | |
| source_type | Ecto.Enum | not null; values: `[:git_repo, :jira_project, :drive_folder]` | |
| name | :string | not null | human label, e.g. "backend-api" |
| identifier | :string | not null | repo URL/path, Jira project key, Drive folder id |
| policy | Ecto.Enum | not null; default `:allow`; values `[:allow, :deny]` | denylist wins at ingest time |
| active | :boolean | not null, default true | soft on/off without deleting sync state |
| config | :map (jsonb) | default `%{}` | e.g. `%{"jql_extra" => "...", "recursive" => true, "branch" => "main"}` |
| inserted_at/updated_at | utc_datetime_usec | | |

**Indexes**: unique `[:source_type, :identifier]` (natural key, prevents
duplicate source registration); btree `[:policy]`, `[:active]` for the
ingestion scheduler's "which sources do I sync" query.

## 3 & 4. `chunks` table + indexes

**Fields**:
| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | :binary_id | PK | |
| source_id | :binary_id | FK -> sources, `on_delete: :delete_all`, not null | deleting a source purges its chunks |
| source_type | Ecto.Enum | not null (denormalized copy of sources.source_type) | avoids join for the hot filter path |
| repo | :string | nullable | git repo identifier; null for jira/drive |
| lang | :string | nullable | tree-sitter-detected language; null for jira/drive |
| chunk_key | :string | not null | stable natural key: `sha256(source_id \| path_or_key \| symbol_or_section \| chunk_index)` |
| content_hash | :string | not null | `sha256(content)` — detects real content changes vs just re-touched file |
| content | :text | not null | |
| context_breadcrumb | :text | not null | `path.ex > MyModule > my_func/2` or `Doc Title > Section > Subsection` |
| metadata | :map (jsonb) | default `%{}` | source-specific back-links (see below) |
| embedding | `Pgvector.Ecto.Vector` `vector(384)` | nullable until embedded | Matryoshka-truncated nomic-embed-text-v1.5 |
| tsv | `:tsvector` (generated) | not null, DB-generated | `to_tsvector('english', breadcrumb || ' ' || content)` |
| parse_status | Ecto.Enum | not null, default `:ok`; values `[:ok, :heuristic_fallback, :crashed_fallback]` | tree-sitter crash-fallback tier |
| secrets_status | Ecto.Enum | not null, default `:clean`; values `[:clean, :redacted]` | quick filter; full detail in audit log |
| inserted_at/updated_at | utc_datetime_usec | | |

`metadata` shape per `source_type` (documented, not enforced by DB):
- `:git_repo` → `%{"ref" => "abc123", "path" => "lib/foo.ex", "start_line" => 10, "end_line" => 42}`
- `:jira_project` → `%{"issue_key" => "PROJ-123", "issue_type" => "Bug", "resolutiondate" => "..."}`
- `:drive_folder` → `%{"doc_url" => "...", "doc_id" => "...", "revision_id" => "..."}`

**Idempotent upsert key**: unique index on `[:source_id, :chunk_key]` used as
the `ON CONFLICT` target. `content_hash` is compared in the upsert's `SET ...
WHERE chunks.content_hash IS DISTINCT FROM EXCLUDED.content_hash` clause so
re-running ingestion on unchanged files is a no-op (no wasted re-embedding).

**Deletions** (Drive unshare, repo file removal, Jira issue falling out of
the resolved-JQL window): scoped by `(source_id, ` the natural prefix of
`chunk_key` `)` — e.g. `DELETE FROM chunks WHERE source_id = $1 AND
metadata->>'path' = $2` for a removed git file, or `WHERE source_id = $1 AND
metadata->>'issue_key' = $2` for Jira, or `WHERE source_id = $1 AND
metadata->>'doc_id' = $2` for Drive. For a git file that shrank to fewer
chunks, delete every `chunk_key` for that path not present in the freshly
computed chunk set (`WHERE source_id = $1 AND metadata->>'path' = $2 AND
chunk_key NOT IN (...)`), rather than a chunk-index range, since `chunk_key`
already encodes chunk identity via the symbol/section + index hash.

**Indexes**:
- `CREATE INDEX ... USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)` — pgvector HNSW; not expressible via Ecto's index DSL, added via `execute/2` raw SQL, built `CONCURRENTLY` outside a DDL transaction.
- `CREATE INDEX ... USING gin (tsv)` — FTS.
- unique btree `[:source_id, :chunk_key]` — upsert target.
- btree `[:source_type]`, `[:repo]`, `[:lang]` — MCP tool filters.
- btree `[:parse_status]` — ops/debugging query ("show me all crashed-fallback chunks").
- btree `[:content_hash]` — supports the ingestion pipeline's pre-check ("which of these incoming chunk_keys already have this exact hash, so I can skip embedding them") without scanning the whole table.

## 5. Sync-state / watermark table

**Decision: one `sync_states` table**, 1:1 with `sources` (`source_id`
unique FK), with a `cursor` jsonb column rather than per-source-type columns
or three separate tables.

Justification: this is *state storage*, not an association — there's no
referential-integrity or join concern that per-source-type columns would
solve, and the three cursor shapes (Jira `resolutiondate` timestamp, Drive
`start_page_token` string, git `last_sha` per-repo) are mutually exclusive
per row (only one is ever populated), which is exactly the "sparse,
shape-varies-by-type" case jsonb suits. A single table also gives the
scheduler one query ("which sources are due for sync") instead of three.

**Fields**:
| Field | Type | Notes |
|-------|------|-------|
| id | :binary_id | PK |
| source_id | :binary_id | FK -> sources, unique, `on_delete: :delete_all` |
| cursor | :map (jsonb) | `%{"resolutiondate_watermark" => "..."}` / `%{"start_page_token" => "..."}` / `%{"last_sha" => "..."}` |
| status | Ecto.Enum | `[:idle, :syncing, :error]` |
| last_synced_at | utc_datetime_usec | nullable |
| last_error | :text | nullable |
| inserted_at/updated_at | utc_datetime_usec | |

## 6. Secret-detection audit log

**`secret_findings` table** — append-only, never updated (redact-in-place
happens on the chunk; this table is the permanent record of *what* was
found, not the secret itself).

| Field | Type | Notes |
|-------|------|-------|
| id | :binary_id | PK |
| chunk_id | :binary_id | FK -> chunks, nullable, `on_delete: :nilify_all` (chunk may later be deleted/re-ingested; keep the audit row) |
| source_id | :binary_id | FK -> sources, `on_delete: :delete_all` |
| file_reference | :text | path / Jira key / doc URL at detection time |
| detector | Ecto.Enum | `[:gitleaks, :regex_scanner]` |
| rule_id | :string | e.g. gitleaks rule name or internal regex id |
| secret_type | :string | e.g. `"aws_access_key_id"` |
| span | :map (jsonb) | `%{"start_line" => .., "end_line" => .., "start_col" => .., "end_col" => ..}` |
| match_hash | :string | `sha256` of the matched text — never store the raw secret |
| action | Ecto.Enum | `[:redacted, :flagged]` |
| detected_at | utc_datetime_usec | |

Indexes: btree `[:chunk_id]`, `[:source_id]`, `[:detected_at]` (recent-findings dashboard query).

## 7. Hybrid search (RRF) query

Implemented as `RetrievalNode.Search.HybridQuery.search/1` using
`Ecto.Query.with_cte/3` for two CTEs (`vector_search`, `fts_search`), each
computing `row_number() OVER (ORDER BY ...)`, then an outer query doing a
`FULL OUTER JOIN` on chunk id, computing
`COALESCE(1.0/(60+v.rank),0) + COALESCE(1.0/(60+f.rank),0)` as fused score,
joined back to `chunks` for the returned fields, filtered by optional
`source_id`/`repo`/`lang`, ordered by fused score desc, limited by
`top_k` (default 20). Filters are applied *inside* both CTEs (not just the
outer query) so the `ORDER BY` window functions rank only the
already-filtered candidate set — otherwise a repo filter could exclude the
single best cosine match while still consuming its rank-1 slot.

The result set returned by `search/1` is the chunk struct + `fused_score`
only — full `content` is included since it's already loaded on `chunk`, but
callers building MCP tool responses should project only the back-link
fields (`id`, `source_type`, `repo`, `lang`, `context_breadcrumb`,
`metadata`) plus `fused_score` into the wire response, and fetch full
`content` in a second targeted lookup only when a result is actually
expanded — keeps the hot search response small.

Full migrations, schema modules (`Source`, `Chunk`, `SyncState`,
`SecretFinding`), changesets, and the complete `HybridQuery` module
(including the raw CTE SQL) are written in this file below the summary — see
code fences in the sections above for schema/migration and the dedicated
"Code" appendix for the query module.

---

## Appendix: Migrations

```elixir
defmodule RetrievalNode.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
```

```elixir
defmodule RetrievalNode.Repo.Migrations.CreateSources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_type, :string, null: false
      add :name, :string, null: false
      add :identifier, :string, null: false
      add :policy, :string, null: false, default: "allow"
      add :active, :boolean, null: false, default: true
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:source_type, :identifier])
    create index(:sources, [:policy])
    create index(:sources, [:active])
  end
end
```

```elixir
defmodule RetrievalNode.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def change do
    create table(:chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :source_type, :string, null: false
      add :repo, :string
      add :lang, :string
      add :chunk_key, :string, null: false
      add :content_hash, :string, null: false
      add :content, :text, null: false
      add :context_breadcrumb, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :embedding, :vector, size: 384
      add :parse_status, :string, null: false, default: "ok"
      add :secrets_status, :string, null: false, default: "clean"

      timestamps(type: :utc_datetime_usec)
    end

    # Generated tsvector column — added via raw SQL (no Ecto DSL for GENERATED ALWAYS AS).
    execute(
      """
      ALTER TABLE chunks
      ADD COLUMN tsv tsvector
      GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(context_breadcrumb, '') || ' ' || coalesce(content, ''))
      ) STORED
      """,
      "ALTER TABLE chunks DROP COLUMN tsv"
    )

    create unique_index(:chunks, [:source_id, :chunk_key])
    create index(:chunks, [:source_type])
    create index(:chunks, [:repo])
    create index(:chunks, [:lang])
    create index(:chunks, [:parse_status])
    create index(:chunks, [:content_hash])
  end
end
```

```elixir
defmodule RetrievalNode.Repo.Migrations.CreateChunkSearchIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY chunks_embedding_hnsw_idx
    ON chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute """
    CREATE INDEX CONCURRENTLY chunks_tsv_gin_idx
    ON chunks USING gin (tsv)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_hnsw_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_tsv_gin_idx"
  end
end
```

```elixir
defmodule RetrievalNode.Repo.Migrations.CreateSyncStates do
  use Ecto.Migration

  def change do
    create table(:sync_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :cursor, :map, null: false, default: %{}
      add :status, :string, null: false, default: "idle"
      add :last_synced_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sync_states, [:source_id])
  end
end
```

```elixir
defmodule RetrievalNode.Repo.Migrations.CreateSecretFindings do
  use Ecto.Migration

  def change do
    create table(:secret_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chunk_id, references(:chunks, type: :binary_id, on_delete: :nilify_all)
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :file_reference, :text, null: false
      add :detector, :string, null: false
      add :rule_id, :string, null: false
      add :secret_type, :string, null: false
      add :span, :map, null: false, default: %{}
      add :match_hash, :string, null: false
      add :action, :string, null: false
      add :detected_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:secret_findings, [:chunk_id])
    create index(:secret_findings, [:source_id])
    create index(:secret_findings, [:detected_at])
  end
end
```

## Appendix: Schema modules

```elixir
defmodule RetrievalNode.Retrieval.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sources" do
    field :source_type, Ecto.Enum, values: [:git_repo, :jira_project, :drive_folder]
    field :name, :string
    field :identifier, :string
    field :policy, Ecto.Enum, values: [:allow, :deny], default: :allow
    field :active, :boolean, default: true
    field :config, :map, default: %{}

    has_many :chunks, RetrievalNode.Retrieval.Chunk
    has_one :sync_state, RetrievalNode.Retrieval.SyncState

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_type, :name, :identifier]
  @optional [:policy, :active, :config]

  def create_changeset(source, attrs) do
    source
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:source_type, :identifier])
  end

  def update_changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :policy, :active, :config])
  end
end
```

```elixir
defmodule RetrievalNode.Retrieval.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chunks" do
    field :source_type, Ecto.Enum, values: [:git_repo, :jira_project, :drive_folder]
    field :repo, :string
    field :lang, :string
    field :chunk_key, :string
    field :content_hash, :string
    field :content, :string
    field :context_breadcrumb, :string
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector
    field :parse_status, Ecto.Enum, values: [:ok, :heuristic_fallback, :crashed_fallback], default: :ok
    field :secrets_status, Ecto.Enum, values: [:clean, :redacted], default: :clean

    # tsv is DB-generated; expose read-only for introspection/debugging only
    field :tsv, RetrievalNode.EctoTypes.TsVector, load_only: true

    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :source_type, :chunk_key, :content_hash, :content, :context_breadcrumb]
  @optional [:repo, :lang, :metadata, :embedding, :parse_status, :secrets_status]

  @doc """
  Ingestion upsert changeset. Called from internal ingestion pipeline
  (not external user input), but still uses cast/validate for defense in
  depth against malformed scraped content.
  """
  def upsert_changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:source_id, :chunk_key], name: :chunks_source_id_chunk_key_index)
  end
end
```

```elixir
defmodule RetrievalNode.Retrieval.SyncState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sync_states" do
    field :cursor, :map, default: %{}
    field :status, Ecto.Enum, values: [:idle, :syncing, :error], default: :idle
    field :last_synced_at, :utc_datetime_usec
    field :last_error, :string

    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sync_state, attrs) do
    sync_state
    |> cast(attrs, [:source_id, :cursor, :status, :last_synced_at, :last_error])
    |> validate_required([:source_id])
    |> foreign_key_constraint(:source_id)
    |> unique_constraint(:source_id)
  end
end
```

```elixir
defmodule RetrievalNode.Retrieval.SecretFinding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secret_findings" do
    field :file_reference, :string
    field :detector, Ecto.Enum, values: [:gitleaks, :regex_scanner]
    field :rule_id, :string
    field :secret_type, :string
    field :span, :map, default: %{}
    field :match_hash, :string
    field :action, Ecto.Enum, values: [:redacted, :flagged]
    field :detected_at, :utc_datetime_usec

    belongs_to :chunk, RetrievalNode.Retrieval.Chunk
    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :file_reference, :detector, :rule_id, :secret_type, :match_hash, :action, :detected_at]

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, @required ++ [:chunk_id, :span])
    |> validate_required(@required)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
```

## Appendix: Hybrid search query module

```elixir
defmodule RetrievalNode.Search.HybridQuery do
  @moduledoc """
  Reciprocal Rank Fusion (k=60) over pgvector cosine similarity and
  Postgres full-text search, both scoped to the same optional
  source/repo/lang filters before ranking (so filters can't be defeated
  by a candidate ranking highly in the unfiltered set).
  """

  import Ecto.Query
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Chunk

  @rrf_k 60
  @default_top_k 20
  @candidate_pool 200

  @type opts :: [
          embedding: [float()],
          text_query: String.t(),
          source_id: Ecto.UUID.t() | nil,
          repo: String.t() | nil,
          lang: String.t() | nil,
          top_k: pos_integer()
        ]

  @spec search(opts) :: [map()]
  def search(opts) do
    embedding = Keyword.fetch!(opts, :embedding)
    text_query = Keyword.fetch!(opts, :text_query)
    top_k = Keyword.get(opts, :top_k, @default_top_k)

    filtered = filtered_chunks(opts)

    vector_cte =
      from c in filtered,
        select: %{
          id: c.id,
          rank: fragment("row_number() OVER (ORDER BY ? <=> ?)", c.embedding, ^Pgvector.new(embedding))
        },
        where: not is_nil(c.embedding),
        limit: ^@candidate_pool

    fts_cte =
      from c in filtered,
        where: fragment("? @@ websearch_to_tsquery('english', ?)", c.tsv, ^text_query),
        select: %{
          id: c.id,
          rank:
            fragment(
              "row_number() OVER (ORDER BY ts_rank(?, websearch_to_tsquery('english', ?)) DESC)",
              c.tsv,
              ^text_query
            )
        },
        limit: ^@candidate_pool

    query =
      Chunk
      |> with_cte("vector_search", as: ^vector_cte)
      |> with_cte("fts_search", as: ^fts_cte)
      |> join(:full, [c], v in "vector_search", on: v.id == c.id, as: :v)
      |> join(:full, [c, v], f in "fts_search", on: f.id == coalesce(v.id, c.id), as: :f)
      |> where([c, v, f], not is_nil(v.id) or not is_nil(f.id))
      |> join(:inner, [c, v, f], ch in Chunk, on: ch.id == coalesce(v.id, f.id), as: :chunk)
      |> select([c, v, f, ch], %{
        chunk: ch,
        fused_score:
          fragment(
            "COALESCE(1.0 / (? + ?), 0) + COALESCE(1.0 / (? + ?), 0)",
            ^@rrf_k,
            v.rank,
            ^@rrf_k,
            f.rank
          )
      })
      |> order_by([..., fused_score: nil], fragment("fused_score DESC"))
      |> limit(^top_k)

    Repo.all(query)
  end

  # Applies optional source/repo/lang filters once, shared by both CTEs,
  # so ranking only ever happens over the already-filtered candidate set.
  defp filtered_chunks(opts) do
    Chunk
    |> maybe_filter(:source_id, opts[:source_id])
    |> maybe_filter(:repo, opts[:repo])
    |> maybe_filter(:lang, opts[:lang])
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :source_id, value), do: from(c in query, where: c.source_id == ^value)
  defp maybe_filter(query, :repo, value), do: from(c in query, where: c.repo == ^value)
  defp maybe_filter(query, :lang, value), do: from(c in query, where: c.lang == ^value)
end
```

Note: the `order_by` fragment on a computed alias (`fused_score`) and the
double `full join` against two CTEs is at the edge of what `Ecto.Query`'s
macro DSL expresses cleanly. If the composed query above proves awkward in
practice, fall back to a single hand-written raw SQL string executed via
`Repo.query/3` with positional `$1..$n` params built from the same
`opts` — functionally identical, just easier to read for a 2-CTE RRF join.
Both approaches keep filters applied inside each CTE, which is the
important correctness property, not the surface syntax.

The equivalent raw SQL form (recommended default — a 2-CTE RRF fusion with
window functions is right at the edge of Ecto's `with_cte`/`fragment` DSL,
and hand-tuning against `EXPLAIN ANALYZE` is far easier against a plain
`.sql` file than a macro-generated query):

```sql
-- $1 :: vector(384)   query embedding, e.g. Pgvector.new(embedding)
-- $2 :: text           free-form query text (websearch_to_tsquery syntax)
-- $3 :: int             RRF k (60)
-- $4 :: int             top_k result limit
-- $5 :: uuid OR NULL    source_id filter
-- $6 :: text OR NULL    repo filter
-- $7 :: text OR NULL    lang filter
WITH candidates AS (
  SELECT id FROM chunks
  WHERE ($5::uuid IS NULL OR source_id = $5)
    AND ($6::text IS NULL OR repo = $6)
    AND ($7::text IS NULL OR lang = $7)
),
vector_search AS (
  SELECT c.id, row_number() OVER (ORDER BY c.embedding <=> $1::vector) AS rank
  FROM chunks c JOIN candidates ON candidates.id = c.id
  WHERE c.embedding IS NOT NULL
  ORDER BY c.embedding <=> $1::vector
  LIMIT 200
),
fts_search AS (
  SELECT c.id, row_number() OVER (
    ORDER BY ts_rank(c.tsv, websearch_to_tsquery('english', $2)) DESC
  ) AS rank
  FROM chunks c JOIN candidates ON candidates.id = c.id
  WHERE c.tsv @@ websearch_to_tsquery('english', $2)
  ORDER BY ts_rank(c.tsv, websearch_to_tsquery('english', $2)) DESC
  LIMIT 200
),
fused AS (
  SELECT id, SUM(1.0 / ($3 + rank)) AS score
  FROM (
    SELECT id, rank FROM vector_search
    UNION ALL
    SELECT id, rank FROM fts_search
  ) ranked
  GROUP BY id
)
SELECT
  c.id, c.source_type, c.repo, c.lang, c.context_breadcrumb, c.metadata,
  fused.score AS fused_score
FROM fused
JOIN chunks c ON c.id = fused.id
ORDER BY fused.score DESC
LIMIT $4;
```

`content` is deliberately not selected in the raw-SQL form either — fetch it
in a second `Repo.get/2` keyed on the returned `id` only when a result is
expanded, so the hot search path stays row/token-lean.

## Gotchas

1. **pgvector version mismatch — resolve before writing migrations against
   this doc**: the pinned `pgvector` **v0.4.0** is the *Elixir hex client*
   version. The Postgres **extension** must independently be **>= 0.5.0**
   for `hnsw` index support at all (0.4.x-era extension only ships
   `ivfflat`). Confirm the target box's extension version with `SELECT
   extversion FROM pg_extension WHERE extname = 'vector';` before running
   `CreateChunkSearchIndexes` — if it's < 0.5.0, upgrade the OS package /
   extension (independent of the hex client pin) or the `USING hnsw`
   migration will fail outright.
2. **Vector type registration**: `Pgvector.Ecto.Vector` requires Postgrex to
   know how to encode/decode the `vector` OID — configure a custom
   `Postgrex.Types` module (per the `pgvector` hex package README) and point
   `Repo` config's `:types` at it. Skipping this doesn't error loudly; `<=>`
   comparisons can silently misbehave or the cast fails at param-binding
   time with a cryptic Postgrex error, not an obvious "you forgot to
   register the type" message.
3. **HNSW build memory**: `CREATE INDEX ... USING hnsw` holds the graph in
   `maintenance_work_mem` during build. At hundreds-of-thousands of 384-dim
   vectors, roughly ~1–2KB/vector (data + `m`-degree graph edges) means
   `SET maintenance_work_mem = '1GB'` (session-scoped, right before the
   `CREATE INDEX CONCURRENTLY` in `CreateChunkSearchIndexes`) on the
   modest-RAM ARM target — the Postgres default (64MB) will make the build
   swap heavily or fail. `CONCURRENTLY` avoids locking `chunks` for writes
   during the (potentially multi-minute) build, at the cost of ~2x disk I/O
   for the build itself.
4. **Generated tsvector column requires an immutable expression**:
   `GENERATED ALWAYS AS (to_tsvector('english', ...)) STORED` works because
   `'english'` is a literal regconfig, not a column reference — this is
   valid from Postgres 12+ (no version risk on any modern target). If
   per-row language detection is ever wanted (e.g. non-English Drive docs),
   a dynamic regconfig can't live in a generated column; that would need a
   plain (non-generated) `tsv` column maintained by a trigger or updated
   from the ingestion pipeline instead.
5. **RRF candidate-pool size (`LIMIT 200` in each CTE)**: this bounds both
   the ANN scan and the FTS scan *before* fusion. Too small starves recall
   on whichever signal ranks the true match past rank 200; too large slows
   the `GROUP BY` in the fusion step. 200 is a reasonable starting point at
   hundreds-of-thousands-of-rows scale — tune against the benchmark
   protocol's nDCG@10 target, not blindly.
6. **`websearch_to_tsquery` over `plainto_tsquery`/`to_tsquery`**: the raw
   SQL form above uses `websearch_to_tsquery` (not `plainto_tsquery`, shown
   in the Ecto appendix's `fts_cte` — align the two before shipping) because
   it accepts free-form user query text (quoted phrases, `-exclude`, `OR`)
   safely without the MCP tool caller needing to pre-build tsquery syntax.
   Pick one function and use it consistently across the Ecto and raw-SQL
   code paths in this doc.
7. **`filtered_chunks/1`'s shared filter must apply inside both CTEs, not
   just the outer query** (already reflected above) — a repo filter applied
   only after fusion would let an out-of-scope chunk consume a rank-1 slot
   in the window function and starve an in-scope chunk of that pool
   position, silently degrading recall for filtered queries specifically.
