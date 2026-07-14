defmodule RetrievalNode.Retrieval.PendingChunk do
  @moduledoc """
  Transient staging row for the ingest pipeline. Keeps raw/intermediate content
  OUT of Oban args (Iron Law: args are IDs only). A `*Sync` worker inserts `raw`
  rows; `ChunkFiles` scrubs + splits a raw row into N chunk rows (sharing
  `natural_key`); `EmbedBatch` fills `embedding`; `UpsertChunks` writes the
  permanent `Retrieval.Chunk` rows and deletes the consumed staging rows.

  Uses a `bigserial` primary key (throwaway staging, not a domain entity), unlike
  the binary-id domain schemas.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}

  schema "pending_chunks" do
    field :source, :string
    field :natural_key, :string
    field :content_hash, :string
    field :raw_content, :string
    field :chunk_index, :integer
    field :chunk_content, :string
    field :status, :string, default: "raw"
    field :scrub_mode, :string
    field :chunk_quality, :string
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for a freshly-discovered raw row (`*Sync` workers)."
  def raw_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:source, :natural_key, :content_hash, :raw_content, :status])
    |> put_change(:status, "raw")
    |> validate_required([:source, :natural_key, :content_hash, :raw_content])
  end

  @doc "Changeset for a chunk row split out of a raw row (`ChunkFiles`)."
  def chunk_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [
      :source,
      :natural_key,
      :content_hash,
      :chunk_index,
      :chunk_content,
      :status,
      :scrub_mode,
      :chunk_quality,
      :embedding
    ])
    |> validate_required([:source, :natural_key, :content_hash, :chunk_index, :chunk_content])
  end
end
