defmodule RetrievalNode.Repo.Migrations.CreateSyncStates do
  use Ecto.Migration

  def change do
    create table(:sync_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :cursor, :map, null: false, default: %{}
      add :status, :string, null: false, default: "idle"
      add :last_synced_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sync_states, [:source_id])
  end
end
