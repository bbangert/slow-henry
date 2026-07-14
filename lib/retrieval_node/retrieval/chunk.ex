defmodule RetrievalNode.Retrieval.Chunk do
  @moduledoc """
  A single embedded, searchable unit of content from any source. One unified table
  so the RRF hybrid query can rank across all sources in one HNSW/GIN scan. Hot-path
  filters are real indexed columns: the query filters `source_id`/`repo`/`lang`
  (all btree-indexed), and `source_type` is indexed too for tool-level filtering.
  Source-varying back-links live in `metadata` jsonb. `tsv` is DB-generated and read-only.
  """
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

    field :parse_status, Ecto.Enum,
      values: [:ok, :heuristic_fallback, :crashed_fallback],
      default: :ok

    field :secrets_status, Ecto.Enum, values: [:clean, :redacted], default: :clean

    # tsv is DB-generated (GENERATED ALWAYS ... STORED). `writable: :never` keeps
    # the pipeline from ever trying to insert/update it; `load_in_query: false`
    # keeps it off the default select (hot search path stays lean) while still
    # allowing an explicit `select: [c.tsv]` for introspection/debugging.
    field :tsv, RetrievalNode.EctoTypes.TsVector, writable: :never, load_in_query: false

    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :source_type, :chunk_key, :content_hash, :content, :context_breadcrumb]
  @optional [:repo, :lang, :metadata, :embedding, :parse_status, :secrets_status]

  @doc """
  Ingestion upsert changeset. Called from the internal ingestion pipeline
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
