defmodule RetrievalNode.Repo.Migrations.AddIngestGenerationToPendingChunks do
  use Ecto.Migration

  # Carries the per-file ingest generation (the RAW row's own `id` — see the
  # `chunks.ingest_generation` migration for the full rationale) from
  # ChunkFiles' raw row onto the chunk rows it splits out, so EmbedBatch and
  # UpsertChunks can read it back off the staged rows without a job-args
  # round trip. Deliberately its own column rather than a `metadata` key:
  # `metadata` is copied verbatim into permanent chunks and returned by MCP
  # search (same reasoning as the `graph` column above it). Nullable and
  # unbacked by any default — staging is transient (drains to empty on every
  # successful run), so there's nothing to backfill.
  def change do
    alter table(:pending_chunks) do
      add :ingest_generation, :bigint, null: true
    end
  end
end
