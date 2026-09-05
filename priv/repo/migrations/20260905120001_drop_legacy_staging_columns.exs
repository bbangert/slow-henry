defmodule RetrievalNode.Repo.Migrations.DropLegacyStagingColumns do
  use Ecto.Migration

  # Final cutover cleanup. The old ChunkFiles -> EmbedBatch -> UpsertChunks
  # pipeline split a raw `pending_chunks` row into intermediate chunk rows and
  # carried their per-chunk state in these columns. `Ingest.FileIngest.apply/2`
  # (via `Ingest.SourceOwner`) writes straight into `Retrieval.Chunk` in one
  # transaction with no intermediate chunk-row stage, so nothing has written or
  # read these since the owner pipeline shipped — the schema fields were removed
  # with the workers; this drops the now-dead columns.
  #
  # `remove_if_exists` (DROP COLUMN IF EXISTS) so the migration is idempotent
  # across environments — a DB that already dropped some of these out-of-band
  # (the dev corpus did, via a different branch) still migrates cleanly.
  # `down/0` restores the column SHAPE (types/defaults from the original
  # create/extend migrations), not the data.
  def up do
    alter table(:pending_chunks) do
      remove_if_exists :chunk_index, :integer
      remove_if_exists :chunk_content, :text
      remove_if_exists :chunk_key, :string
      remove_if_exists :context_breadcrumb, :text
      remove_if_exists :parse_status, :string
      remove_if_exists :secrets_status, :string
      remove_if_exists :scrub_mode, :text
      remove_if_exists :chunk_quality, :text
      remove_if_exists :embedding, :vector
    end
  end

  def down do
    alter table(:pending_chunks) do
      add :chunk_index, :integer
      add :chunk_content, :text
      add :chunk_key, :string
      add :context_breadcrumb, :text
      add :parse_status, :string, null: false, default: "ok"
      add :secrets_status, :string, null: false, default: "clean"
      add :scrub_mode, :text
      add :chunk_quality, :text
      add :embedding, :vector, size: 384
    end
  end
end
