defmodule RetrievalNode.Retrieval.SyncState do
  @moduledoc """
  Per-source sync watermark, 1:1 with `sources`. `cursor` jsonb holds the
  mutually-exclusive per-source-type cursor shape (git `last_sha`, Jira
  `resolutiondate_watermark`, Drive `start_page_token`).
  """
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
