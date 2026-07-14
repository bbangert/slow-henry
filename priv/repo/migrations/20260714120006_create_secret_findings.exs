defmodule RetrievalNode.Repo.Migrations.CreateSecretFindings do
  use Ecto.Migration

  def change do
    create table(:secret_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chunk_id, references(:chunks, type: :binary_id, on_delete: :nilify_all)
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :file_reference, :text, null: false
      add :detector, :string, null: false
      add :rule_id, :string, null: false
      add :secret_type, :string, null: false
      add :span, :map, null: false, default: %{}
      add :match_hash, :string, null: false
      add :action, :string, null: false
      add :detected_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:secret_findings, [:chunk_id])
    create index(:secret_findings, [:source_id])
    create index(:secret_findings, [:detected_at])
  end
end
