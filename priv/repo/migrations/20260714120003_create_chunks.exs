defmodule RetrievalNode.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def change do
    create table(:chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :source_type, :string, null: false
      add :repo, :string
      add :lang, :string
      add :chunk_key, :string, null: false
      add :content_hash, :string, null: false
      add :content, :text, null: false
      add :context_breadcrumb, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :embedding, :vector, size: 384
      add :parse_status, :string, null: false, default: "ok"
      add :secrets_status, :string, null: false, default: "clean"

      timestamps(type: :utc_datetime_usec)
    end

    # Generated tsvector column — added via raw SQL (no Ecto DSL for GENERATED ALWAYS AS).
    # The regconfig must be a literal ('english'), not a column reference, for the
    # expression to be immutable enough for a STORED generated column.
    execute(
      """
      ALTER TABLE chunks
      ADD COLUMN tsv tsvector
      GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(context_breadcrumb, '') || ' ' || coalesce(content, ''))
      ) STORED
      """,
      "ALTER TABLE chunks DROP COLUMN tsv"
    )

    create unique_index(:chunks, [:source_id, :chunk_key])
    create index(:chunks, [:source_type])
    create index(:chunks, [:repo])
    create index(:chunks, [:lang])
    create index(:chunks, [:parse_status])
    create index(:chunks, [:content_hash])
  end
end
