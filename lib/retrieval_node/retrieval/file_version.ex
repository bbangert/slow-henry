defmodule RetrievalNode.Retrieval.FileVersion do
  @moduledoc """
  One row per `(source_id, identity)` recording the highest ingest generation
  ever claimed for that file — the atomic serialization point
  `Ingest.claim_file_version/4` claims against with a row-locked
  compare-and-set. See that function and the `file_versions` migration for
  the concurrency story this table exists to solve.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "file_versions" do
    field :identity, :string
    field :generation, :integer

    belongs_to :source, RetrievalNode.Retrieval.Source

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :identity, :generation]

  @doc "Minimal changeset — `claim_file_version/4` writes via `insert_all`, not this; kept for parity with sibling schemas and any future direct-write callers."
  def changeset(file_version, attrs) do
    file_version
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:source_id, :identity])
  end
end
