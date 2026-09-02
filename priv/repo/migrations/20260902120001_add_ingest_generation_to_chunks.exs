defmodule RetrievalNode.Repo.Migrations.AddIngestGenerationToChunks do
  use Ecto.Migration

  @moduledoc false

  # Monotonic per-file ingest generation, used to make chunk upserts and
  # per-file reconciliation order-safe. Two versions of one file can be in
  # flight at once (a retried EmbedBatch, or an hours-deep embed backlog), and
  # ChunkFiles/EmbedBatch/UpsertChunks are unique only by staging-row ids — so
  # the OLDER version's terminal job can run last, overwriting newer content
  # and (since per-file reconciliation landed) deleting the newer version's
  # chunks. The generation is the raw `pending_chunks` row id of the file
  # version that produced the chunk (bigserial ⇒ monotonic per database);
  # UpsertChunks and ChunkFiles' zero-chunk path skip a batch whose generation
  # is older than the one already persisted for that file identity.
  #
  # Nullable: legacy rows predate the column and are treated as generation 0
  # (any real batch wins over them). Deliberately additive — no backfill.
  def change do
    alter table(:chunks) do
      add :ingest_generation, :bigint, null: true
    end
  end
end
