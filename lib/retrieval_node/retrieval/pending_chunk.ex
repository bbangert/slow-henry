defmodule RetrievalNode.Retrieval.PendingChunk do
  @moduledoc """
  A per-source mailbox entry for the ingest pipeline: one raw file version (or
  a deletion) waiting to be applied. Keeps raw content OUT of Oban args (Iron
  Law: args are IDs only) — a `*Sync` worker (`RepoSync`/`DriveSync`/
  `JiraSync`) appends a `status: "raw"` row carrying a file's content plus
  source provenance, or a `status: "deleted"` row (via `deletion_changeset/2`)
  carrying just its identity, then calls `Ingest.SourceOwner.notify/1`.

  `Ingest.SourceOwner` is the only reader: it drains a source's rows oldest
  first (the bigserial `id` is arrival order), collapsing to the newest row
  per file identity, and calls `Ingest.FileIngest.apply/2` once per kept row.
  `apply/2` deletes the row on every successful outcome — there is no
  intermediate chunk-row stage here; a raw row is applied straight into the
  permanent `Retrieval.Chunk` table in one transaction. `attempts`/
  `last_error`/`retry_after` are the owner's per-row bookkeeping for a row
  that keeps failing; `force` marks a forced re-derive.

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

    # chunk-level: unused by the current owner-applied pipeline (FileIngest
    # writes straight to Retrieval.Chunk in one transaction, no intermediate
    # chunk-row stage); left in the schema/table rather than migrated away.
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
  @doc "Changeset for a freshly-discovered raw row (`*Sync` workers)."
  def raw_changeset(pending_chunk, attrs) do
    pending_chunk
    # `:force` is castable here too so the single-row API can stage a forced
    # re-derive; `insert_raw_all/1`'s bulk path already passes it through.
    |> cast(attrs, [:raw_content, :force | @provenance])
    |> put_change(:status, "raw")
    # source_id/source_type are provenance Ingest.FileIngest assumes exists —
    # require them so a raw row can't be staged without them.
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
  """
  def deletion_changeset(pending_chunk, attrs) do
    pending_chunk
    |> cast(attrs, [:source, :source_id, :source_type, :natural_key, :metadata])
    |> put_change(:status, "deleted")
    |> validate_required([:source, :source_id, :source_type, :natural_key, :metadata])
  end
end
