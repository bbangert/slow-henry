defmodule RetrievalNode.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  # HNSW indexes (CreateChunkSearchIndexes) require the pgvector *extension* to be
  # >= 0.5.0 — independent of the hex client version. Assert it here so a too-old
  # extension fails loudly at the first migration rather than cryptically at the
  # HNSW build. `pg_extension.extversion` is the installed extension version.
  @min_vector_version "0.5.0"

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    assert_vector_version!()
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS vector"
  end

  defp assert_vector_version! do
    %{rows: [[version]]} =
      repo().query!("SELECT extversion FROM pg_extension WHERE extname = 'vector'")

    if Version.compare(version, @min_vector_version) == :lt do
      raise """
      pgvector extension #{version} is too old — HNSW requires >= #{@min_vector_version}.
      Upgrade the Postgres 'vector' extension (OS package), independent of the hex client.
      """
    end
  end
end
