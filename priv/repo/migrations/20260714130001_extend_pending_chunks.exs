defmodule RetrievalNode.Repo.Migrations.ExtendPendingChunks do
  use Ecto.Migration

  # The staging table (Phase 1) held only the minimal split fields. To let
  # UpsertChunks build a full Retrieval.Chunk row 1:1 without carrying data in
  # Oban args, pending_chunks also needs the Chunk provenance/derived fields:
  # source_id/source_type/repo/lang/metadata (set by *Sync on the raw row),
  # chunk_key/context_breadcrumb/parse_status/secrets_status (set by ChunkFiles on
  # the chunk rows). content_hash of the chunk itself is computed in UpsertChunks.
  def change do
    alter table(:pending_chunks) do
      add :source_id, :binary_id
      add :source_type, :string
      add :repo, :string
      add :lang, :string
      add :chunk_key, :string
      add :context_breadcrumb, :text
      add :metadata, :map, null: false, default: %{}
      add :parse_status, :string, null: false, default: "ok"
      add :secrets_status, :string, null: false, default: "clean"
    end
  end
end
