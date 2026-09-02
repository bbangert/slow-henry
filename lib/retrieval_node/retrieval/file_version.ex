defmodule RetrievalNode.Retrieval.FileVersion do
  @moduledoc """
  One row per `(source_id, identity_hash)` recording the highest ingest
  generation ever claimed for that file — the atomic serialization point
  `Ingest.claim_file_version/4` claims against with a row-locked
  compare-and-set. See that function and the `file_versions` migration for
  the concurrency story this table exists to solve.

  `identity_hash` (see `Ingest.identity_hash/1`) — not `identity` — is the
  actual uniqueness/conflict key: `identity` is unbounded text (an arbitrary
  git path, Drive doc id, etc.) that could exceed PostgreSQL's ~2.7 KB B-tree
  index-tuple limit and make every claim for that file fail forever; the
  fixed-size digest can't. `identity` is still stored on every row as the
  human-readable value for inspection.

  Rows are never deleted for a deleted file. `Ingest.Workers.RepoSync.delete_removed/2`
  handles a file removal as a tombstone claim — drawing a fresh generation via
  `Ingest.next_ingest_generation/1` and claiming it through the same
  compare-and-set — rather than deleting the guard row outright, so a
  still-in-flight pre-deletion job can never mistake the absence of a row for
  "no version has ever claimed this identity" and resurrect deleted chunks. A
  file later re-added at the same identity simply claims a higher generation,
  the same way any edit does.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "file_versions" do
    field :identity, :string
    field :identity_hash, :string
    field :generation, :integer

    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :identity, :generation]

  @doc "Minimal changeset — `claim_file_version/4` writes via `insert_all`, not this; kept for parity with sibling schemas and any future direct-write callers. Derives `identity_hash` from `identity` (see `Ingest.identity_hash/1`) rather than accepting it as caller input."
  def changeset(file_version, attrs) do
    file_version
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> put_identity_hash()
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:source_id, :identity_hash])
  end

  defp put_identity_hash(changeset) do
    case get_field(changeset, :identity) do
      identity when is_binary(identity) ->
        put_change(changeset, :identity_hash, RetrievalNode.Ingest.identity_hash(identity))

      _ ->
        changeset
    end
  end
end
