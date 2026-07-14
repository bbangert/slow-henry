defmodule RetrievalNode.Repo.Migrations.CreatePendingChunks do
  use Ecto.Migration

  # Transient staging table (design-oban.md §"Staging table") that keeps raw and
  # intermediate content OUT of Oban args (Iron Law: args are IDs only). Rows are
  # written by the *Sync workers (status "raw"), split/scrubbed by ChunkFiles, and
  # deleted by UpsertChunks once the permanent chunks rows are written.
  #
  # bigserial PK (not binary_id) — this is throwaway staging, not a domain entity.
  # embedding is vector(384) here too (reconciliation #3): Matryoshka truncation
  # happens in the embedding impl, so nothing downstream ever sees 768.
  def change do
    create table(:pending_chunks) do
      add :source, :text, null: false
      add :natural_key, :text, null: false
      add :content_hash, :text, null: false
      add :raw_content, :text
      add :chunk_index, :integer
      add :chunk_content, :text
      add :status, :text, null: false, default: "raw"
      add :scrub_mode, :text
      add :chunk_quality, :text
      add :embedding, :vector, size: 384

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pending_chunks, [:status])
    create index(:pending_chunks, [:natural_key])
  end
end
