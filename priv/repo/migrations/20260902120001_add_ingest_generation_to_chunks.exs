defmodule RetrievalNode.Repo.Migrations.AddIngestGenerationToChunks do
  use Ecto.Migration

  @moduledoc false

  # Monotonic per-file ingest generation, copied onto the permanent chunk row
  # as PROVENANCE ONLY — the generation is the raw `pending_chunks` row id of
  # the file version that produced the chunk (bigserial ⇒ monotonic per
  # database). This column is never read back to decide whether to skip a
  # batch: that order-safety guard is the atomic claim in `file_versions`
  # (`Ingest.claim_file_version/4`, added by a later migration), a row-locked
  # compare-and-set that serializes concurrent terminal jobs for the same
  # file before any chunk is written. This column just carries the winning
  # claim's generation onto the row for debugging/audit.
  #
  # Nullable: legacy rows predate the column and are treated as generation 0
  # anywhere it IS read. Deliberately additive — no backfill.
  def change do
    alter table(:chunks) do
      add :ingest_generation, :bigint, null: true
    end
  end
end
