defmodule RetrievalNode.Repo.Migrations.CreateSources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_type, :string, null: false
      add :name, :string, null: false
      add :identifier, :string, null: false
      add :policy, :string, null: false, default: "allow"
      add :active, :boolean, null: false, default: true
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:source_type, :identifier])
    create index(:sources, [:policy])
    create index(:sources, [:active])
  end
end
