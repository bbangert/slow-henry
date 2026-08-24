defmodule RetrievalNode.Repo.Migrations.AddGraphToPendingChunks do
  use Ecto.Migration

  # Staging-only carrier for the per-chunk graph payload (entities/references
  # ChunkFiles extracted from the same parse) so it rides the existing
  # pending_chunks row between Oban stages without touching `metadata` —
  # `metadata` is copied verbatim into permanent chunks and returned by MCP
  # search, so the graph payload must never leak there. UpsertChunks reads
  # this column to persist into entities/entity_mentions/entity_edges, then
  # the row (and this column with it) is deleted like the rest of staging.
  def change do
    alter table(:pending_chunks) do
      add :graph, :map, null: false, default: %{}
    end
  end
end
