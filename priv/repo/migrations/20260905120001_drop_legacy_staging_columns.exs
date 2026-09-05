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
  # `down/0` restores the column SHAPE (same types/defaults as the original
  # `create_pending_chunks`/`extend_pending_chunks` migrations), not any data —
  # the dropped columns are gone for good.
  def change do
    alter table(:pending_chunks) do
      remove :chunk_index, :integer
      remove :chunk_content, :text
      remove :chunk_key, :string
      remove :context_breadcrumb, :text
      remove :parse_status, :string, null: false, default: "ok"
      remove :secrets_status, :string, null: false, default: "clean"
      remove :scrub_mode, :text
      remove :chunk_quality, :text
      remove :embedding, :vector, size: 384
    end
  end
end
