defmodule RetrievalNode.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  # HNSW indexes (CreateChunkSearchIndexes) require the pgvector *extension* to be
  # >= 0.5.0 — independent of the hex client version. Assert it here so a too-old
  # extension fails loudly at the first migration rather than cryptically at the
  # HNSW build.
  #
  # The check runs as an in-transaction SQL DO block (not `repo().query!`, which
  # would check out a separate pool connection that can't see the extension this
  # migration just created but hasn't committed). Versions compare element-wise as
  # integer arrays (pgvector versions are numeric, e.g. 0.8.5).
  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    DO $$
    DECLARE
      installed text;
    BEGIN
      SELECT extversion INTO installed FROM pg_extension WHERE extname = 'vector';
      IF installed IS NULL THEN
        RAISE EXCEPTION 'pgvector extension is not installed';
      END IF;
      IF string_to_array(installed, '.')::int[] < string_to_array('0.5.0', '.')::int[] THEN
        RAISE EXCEPTION
          'pgvector extension % is too old — HNSW requires >= 0.5.0. Upgrade the Postgres ''vector'' extension (OS package), independent of the hex client.',
          installed;
      END IF;
    END $$;
    """
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
