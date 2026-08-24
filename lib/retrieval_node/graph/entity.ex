defmodule RetrievalNode.Graph.Entity do
  @moduledoc """
  A code symbol (function/method/class/module) identified by
  `(source_id, language, qualified_name)`. Identity is scoped to its source
  rather than global: the corpus spans 91 repos that share generic names like
  `setup`/`main`, so a global `(language, qualified_name)` key would silently
  merge unrelated functions from different repos into one entity.

  `qualified_name` is the breadcrumb-scoped symbol name (e.g.
  `"PaymentProcessor.process"`) — it does not include a file path. `path` is
  the representative definition file, kept for informational/debugging use
  only: if the same qualified name is defined in two files within one source,
  those definitions deliberately merge into a single entity (best-effort per
  the graph-ingest plan), and `path` reflects whichever definition was seen.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "entities" do
    field :language, :string
    field :qualified_name, :string
    field :kind, Ecto.Enum, values: [:function, :method, :class, :module]
    field :path, :string
    field :metadata, :map, default: %{}

    belongs_to :source, RetrievalNode.Retrieval.Source
    has_many :entity_mentions, RetrievalNode.Graph.EntityMention

    timestamps(type: :utc_datetime_usec)
  end

  @required [:source_id, :language, :qualified_name, :kind]
  @optional [:path, :metadata]

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:source_id, :language, :qualified_name])
  end
end
