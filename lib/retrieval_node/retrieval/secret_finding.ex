defmodule RetrievalNode.Retrieval.SecretFinding do
  @moduledoc """
  Append-only audit record of a detected secret. Never stores the raw secret —
  only `match_hash` (sha256 of the matched text). The chunk is redacted in-place;
  this table records *what* was found. It survives chunk churn: `chunk_id`
  nilifies on chunk deletion so re-ingesting a file keeps its prior findings.
  Deleting the whole `source`, however, cascades (`source_id` on_delete:
  :delete_all) — once a source is de-registered its findings go with it.
  """
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

  @required [
    :source_id,
    :file_reference,
    :detector,
    :rule_id,
    :secret_type,
    :match_hash,
    :action,
    :detected_at
  ]

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, @required ++ [:chunk_id, :span])
    |> validate_required(@required)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
