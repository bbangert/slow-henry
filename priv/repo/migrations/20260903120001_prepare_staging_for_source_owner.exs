defmodule RetrievalNode.Repo.Migrations.PrepareStagingForSourceOwner do
  use Ecto.Migration

  # Additive, applied BEFORE any code depends on it (schema-first rule for the
  # long-lived dev node). `pending_chunks` becomes the per-source FIFO mailbox
  # drained by `Ingest.SourceOwner`:
  #
  #   * `content_hash` becomes nullable so a **deletion entry** (`status:
  #     "deleted"`, no content) can sit in the same queue as content rows and be
  #     applied in arrival order by the owner — no tombstone table needed.
  #   * `attempts`/`last_error`/`retry_after` are the owner's per-row failure
  #     marks: a file that keeps failing is marked and skipped, never blocking
  #     the rest of its source's queue.
  #   * `force` marks a row staged by a graph-only backfill: re-chunk/re-extract
  #     even when the file's content is unchanged (embeddings are reused).
  #   * `(source_id, id)` index: the owner's drain query is "oldest N rows for
  #     this source, in id order".
  #
  # `chunks.file_hash` records the raw file hash each chunk was derived from,
  # so the owner can recognise an unchanged file version and skip it entirely.
  def change do
    alter table(:pending_chunks) do
      modify :content_hash, :text, null: true, from: {:text, null: false}
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :retry_after, :utc_datetime_usec
      add :force, :boolean, null: false, default: false
    end

    create index(:pending_chunks, [:source_id, :id])

    alter table(:chunks) do
      add :file_hash, :text
    end
  end
end
