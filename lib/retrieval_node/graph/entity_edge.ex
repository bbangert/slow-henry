defmodule RetrievalNode.Graph.EntityEdge do
  @moduledoc """
  A definition-site -> call-site relationship between two entities,
  contributed by one chunk. `weight` is the count of extracted reference
  OCCURRENCES this chunk contributed to the edge (one increment per raw
  reference, not deduped). This is distinct from `entity_mentions`, which dedups to one row
  per `(entity, chunk, kind)` — a chunk that calls the same target twice can
  contribute `weight: 2` to an edge while still producing only one `:call`
  mention.

  `chunk_id` is the chunk-level provenance for this row — entities merge one
  `qualified_name` across every file of a source, so two files defining the
  same merged entity each get their own edge row per (source, target, kind),
  keyed by their own chunk. This is what lets one file's re-derivation
  replace only its own contribution without clobbering another file's. It's
  nullable only because legacy rows written before provenance shipped keep
  `chunk_id` NULL. Readers are expected to aggregate (SUM `weight` GROUP BY
  entity pair + kind) across a logical edge's chunk-level rows.

  Schema only: edge writing and traversal land in later PRs.
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
    belongs_to :chunk, RetrievalNode.Retrieval.Chunk

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_entity_id, :target_entity_id, :kind]
  @optional [:weight, :chunk_id]

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:source_entity_id)
    |> foreign_key_constraint(:target_entity_id)
    |> foreign_key_constraint(:chunk_id)
    |> unique_constraint([:source_entity_id, :target_entity_id, :kind, :chunk_id],
      name: :entity_edges_source_target_kind_chunk_index
    )
  end
end
