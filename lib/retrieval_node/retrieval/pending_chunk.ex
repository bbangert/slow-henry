defmodule RetrievalNode.Retrieval.PendingChunk do
  @moduledoc """
  A per-source mailbox entry for the ingest pipeline: one raw file version (or
  a deletion) waiting to be applied. Keeps raw content OUT of Oban args (Iron
  Law: args are IDs only) — a `*Sync` worker (`RepoSync`/`DriveSync`/
  `JiraSync`) appends a `status: "raw"` row carrying a file's content plus
  source provenance, or a `status: "deleted"` row carrying just its identity,
  then calls `Ingest.SourceOwner.notify/1`.

  `Ingest.SourceOwner` is the only reader: it drains a source's rows oldest
  first (the bigserial `id` is arrival order), collapsing to the newest row
  per file identity, and calls `Ingest.FileIngest.apply/2` once per kept row.
  `apply/2` deletes the row on every successful outcome — there is no
  intermediate chunk-row stage here; a raw row is applied straight into the
  permanent `Retrieval.Chunk` table in one transaction.

  Uses a `bigserial` primary key (throwaway staging).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pending_chunks" do
    # staging bookkeeping
    field :status, :string, default: "raw"
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

    # owner drain bookkeeping (Ingest.SourceOwner): a row that keeps failing
    # FileIngest.apply/2 is marked here rather than blocking the rest of its
    # source's queue — attempts/last_error record what happened, retry_after
    # lets the owner skip it until some backoff window passes.
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :retry_after, :utc_datetime_usec
    # Set by a graph-only backfill (`rn.graph.backfill`): re-chunk/re-extract
    # even though the file's content is unchanged — FileIngest still reuses
    # existing embeddings on an unchanged (chunk_key, content_hash).
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

  @doc "Changeset for a freshly-discovered raw row (`*Sync` workers)."
  def raw_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:raw_content | @provenance])
    |> put_change(:status, "raw")
    # source_id/source_type are provenance Ingest.FileIngest.apply/2 assumes
    # exists — require them so a raw row can't be staged without them.
    |> validate_required([
      :source,
      :source_id,
      :source_type,
      :natural_key,
      :content_hash,
      :raw_content
    ])
  end

  @doc """
  Changeset for a **deletion entry** — a mailbox row recording that a file was
  removed at its source, carrying only the identity `Ingest.FileIngest.apply/2`
  needs to reconcile that file's chunks away (no content, no `content_hash`).
  Sits in the same per-source queue as content rows and is applied in arrival
  order, so a file re-added after a deletion just stages a later raw row and
  wins the ordering the normal way — no separate tombstone table.
  """
  def deletion_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:source, :source_id, :source_type, :natural_key, :metadata])
    |> put_change(:status, "deleted")
    |> validate_required([:source, :source_id, :source_type, :natural_key, :metadata])
  end
end
