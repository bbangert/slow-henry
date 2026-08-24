defmodule RetrievalNode.Graph.EntityEdge do
  @moduledoc """
  An aggregated definition-site -> call-site relationship between two
  entities. `weight` is the mention count backing the edge (how many
  `entity_mentions` rows collapsed into it), so graph traversal reads one row
  per relationship instead of scanning `entity_mentions` for every hop.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "entity_edges" do
    field :kind, Ecto.Enum, values: [:calls, :imports]
    field :weight, :integer, default: 1

    belongs_to :source_entity, RetrievalNode.Graph.Entity
    belongs_to :target_entity, RetrievalNode.Graph.Entity

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_entity_id, :target_entity_id, :kind]
  @optional [:weight]

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:source_entity_id)
    |> foreign_key_constraint(:target_entity_id)
    |> unique_constraint([:source_entity_id, :target_entity_id, :kind])
  end
end
