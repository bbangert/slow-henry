defmodule RetrievalNode.Retrieval.PendingChunk do
  @moduledoc """
  Transient staging row for the ingest pipeline. Keeps raw/intermediate content
  OUT of Oban args (Iron Law: args are IDs only). A `*Sync` worker inserts `raw`
  rows carrying source provenance; `ChunkFiles` scrubs + splits a raw row into N
  chunk rows (adding `chunk_key`/`context_breadcrumb`/`parse_status`); `EmbedBatch`
  fills `embedding`; `UpsertChunks` maps the chunk rows 1:1 into permanent
  `Retrieval.Chunk` rows and deletes the consumed staging rows.

  A row may also be a **deletion entry** (`status: "deleted"`, via
  `deletion_changeset/2`) carrying just a file's identity, and may carry
  `attempts`/`last_error`/`retry_after`/`force` — bookkeeping for a future
  per-source drain boundary, unused by the ChunkFiles/EmbedBatch/UpsertChunks
  pipeline today.

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

    # owner drain bookkeeping (a future per-source drain boundary): a row that
    # keeps failing is marked here rather than blocking the rest of its
    # source's queue — attempts/last_error record what happened, retry_after
    # lets the drain skip it until some backoff window passes.
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :retry_after, :utc_datetime_usec
    # Set by a forced re-derive (backfill): re-chunk even though the file's
    # content is unchanged (embeddings are still reused).
    field :force, :boolean, default: false

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
    # source_id/source_type are provenance the downstream pipeline (UpsertChunks)
    # assumes exists — require them so a raw row can't be staged without them.
    |> validate_required([
      :source,
      :source_id,
      :source_type,
      :natural_key,
      :content_hash,
      :raw_content
    ])
  end

  @doc "Changeset for a chunk row split out of a raw row (`ChunkFiles`)."
  def chunk_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:status | @provenance ++ @chunk_fields])
    |> validate_required([:source, :natural_key, :content_hash, :chunk_index, :chunk_content])
  end

  @doc """
  Changeset for a **deletion entry** — a mailbox row recording that a file was
  removed at its source, carrying only the identity `Ingest.FileIngest.apply/2`
  needs to reconcile that file's chunks away (no content, no `content_hash`).
  """
  def deletion_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:source, :source_id, :source_type, :natural_key, :metadata])
    |> put_change(:status, "deleted")
    |> validate_required([:source, :source_id, :source_type, :natural_key, :metadata])
  end
end
