defmodule RetrievalNode.Retrieval.Source do
  @moduledoc """
  A configured ingestion source — a git repo, a Jira project, or a Drive folder —
  with its allow/deny policy and per-source config. `sync_states` points at it 1:1
  and `chunks` belong to it; deleting a source purges both.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sources" do
    field :source_type, Ecto.Enum, values: [:git_repo, :jira_project, :drive_folder]
    field :name, :string
    field :identifier, :string
    field :policy, Ecto.Enum, values: [:allow, :deny], default: :allow
    field :active, :boolean, default: true
    field :config, :map, default: %{}

    has_many :chunks, RetrievalNode.Retrieval.Chunk
    has_one :sync_state, RetrievalNode.Retrieval.SyncState

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_type, :name, :identifier]
  @optional [:policy, :active, :config]

  def create_changeset(source, attrs) do
    source
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:source_type, :identifier])
  end

  def update_changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :policy, :active, :config])
  end
end
