defmodule RetrievalNode.Repo.Migrations.CreateGraphTables do
  use Ecto.Migration

  def change do
    create table(:entities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :language, :text, null: false
      add :qualified_name, :text, null: false
      add :kind, :string, null: false
      add :path, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entities, [:source_id, :language, :qualified_name])

    # Trigram index for fuzzy/substring symbol lookup (e.g. "find entities named
    # like foo_bar" tools). pg_trgm is enabled in EnableExtensions.
    execute(
      "CREATE INDEX entities_qualified_name_trgm_idx ON entities USING gin (qualified_name gin_trgm_ops)",
      "DROP INDEX entities_qualified_name_trgm_idx"
    )

    # entity_mentions ties an entity to every chunk that defines/calls/imports it.
    # At ~586k chunks in the current corpus, this table plausibly grows to
    # 2-5M rows, so chunk_id carries its own index below (independent of the
    # cascade FK) for join/filter performance.
    create table(:entity_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :entity_id, references(:entities, type: :binary_id, on_delete: :delete_all), null: false
      add :chunk_id, references(:chunks, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entity_mentions, [:entity_id, :chunk_id, :kind])
    create index(:entity_mentions, [:chunk_id])

    # entity_edges aggregates def-site -> call-site relationships across mentions
    # (weight = mention count), so graph traversal doesn't need to scan
    # entity_mentions directly. target_entity_id is indexed separately from the
    # cascade FK to support reverse traversal ("who calls X").
    create table(:entity_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :source_entity_id, references(:entities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_entity_id, references(:entities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :weight, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entity_edges, [:source_entity_id, :target_entity_id, :kind])
    create index(:entity_edges, [:target_entity_id])
  end
end
