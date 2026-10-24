defmodule RetrievalNode.Graph.EntityMention do
  @moduledoc """
  Ties an entity to the chunk where it is defined, called, or imported.
  `chunk_id` cascades on delete (`on_delete: :delete_all`) — the ingest
  pipeline's path-based `delete_all` on `chunks` (file deletion/re-ingest)
  cascades here automatically, same lifecycle pattern as `secret_findings`'s
  chunk link, except mentions have no reason to outlive their chunk so there
  is no nilify step.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "entity_mentions" do
    field :kind, Ecto.Enum, values: [:definition, :call, :import]

    belongs_to :entity, RetrievalNode.Graph.Entity
    belongs_to :chunk, RetrievalNode.Retrieval.Chunk

    timestamps(type: :utc_datetime_usec)
  end

  @required [:entity_id, :chunk_id, :kind]

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> foreign_key_constraint(:entity_id)
    |> foreign_key_constraint(:chunk_id)
    |> unique_constraint([:entity_id, :chunk_id, :kind])
  end
end
