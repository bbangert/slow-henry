defmodule RetrievalNode.Repo.Migrations.CreateChunkSearchIndexes do
  use Ecto.Migration

  # HNSW/GIN index builds run CONCURRENTLY, which cannot run inside a
  # transaction or hold the migration advisory lock.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The HNSW graph is held in maintenance_work_mem during the build; the 64MB
    # default swaps heavily at scale. Bump it for this session before building.
    execute "SET maintenance_work_mem = '1GB'"

    execute """
    CREATE INDEX CONCURRENTLY chunks_embedding_hnsw_idx
    ON chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """

    execute """
    CREATE INDEX CONCURRENTLY chunks_tsv_gin_idx
    ON chunks USING gin (tsv)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_hnsw_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_tsv_gin_idx"
  end
end
