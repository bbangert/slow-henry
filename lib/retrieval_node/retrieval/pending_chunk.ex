defmodule RetrievalNode.Retrieval.PendingChunk do
  @moduledoc """
  Transient staging row for the ingest pipeline. Keeps raw/intermediate content
  OUT of Oban args (Iron Law: args are IDs only). A `*Sync` worker inserts `raw`
  rows carrying source provenance; `ChunkFiles` scrubs + splits a raw row into N
  chunk rows (adding `chunk_key`/`context_breadcrumb`/`parse_status`); `EmbedBatch`
  fills `embedding`; `UpsertChunks` maps the chunk rows 1:1 into permanent
  `Retrieval.Chunk` rows and deletes the consumed staging rows.

  Carries the full set of `Chunk` provenance/derived fields so `UpsertChunks` needs
  no data from job args. Uses a `bigserial` primary key (throwaway staging).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pending_chunks" do
    # staging bookkeeping
    field :status, :string, default: "raw"
    field :scrub_mode, :string
    field :chunk_quality, :string
    field :raw_content, :string

    # provenance (set by *Sync on the raw row)
    field :source, :string
    field :source_id, :binary_id
    field :source_type, :string
    field :repo, :string
    field :lang, :string
    field :natural_key, :string
    field :content_hash, :string
    field :metadata, :map, default: %{}

    # chunk-level (set by ChunkFiles)
    field :chunk_index, :integer
    field :chunk_content, :string
    field :chunk_key, :string
    field :context_breadcrumb, :string
    field :parse_status, :string, default: "ok"
    field :secrets_status, :string, default: "clean"
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec)
  end

  @provenance [
    :source,
    :source_id,
    :source_type,
    :repo,
    :lang,
    :natural_key,
    :content_hash,
    :metadata
  ]
  @chunk_fields [
    :chunk_index,
    :chunk_content,
    :chunk_key,
    :context_breadcrumb,
    :parse_status,
    :secrets_status,
    :scrub_mode,
    :chunk_quality,
    :embedding
  ]

  @doc "Changeset for a freshly-discovered raw row (`*Sync` workers)."
  def raw_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:raw_content | @provenance])
    |> put_change(:status, "raw")
    |> validate_required([:source, :natural_key, :content_hash, :raw_content])
  end

  @doc "Changeset for a chunk row split out of a raw row (`ChunkFiles`)."
  def chunk_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:status | @provenance ++ @chunk_fields])
    |> validate_required([:source, :natural_key, :content_hash, :chunk_index, :chunk_content])
  end
end
