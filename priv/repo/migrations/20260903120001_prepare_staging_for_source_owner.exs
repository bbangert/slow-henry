defmodule RetrievalNode.Repo.Migrations.PrepareStagingForSourceOwner do
  use Ecto.Migration

  # Additive, applied BEFORE any code depends on it (schema-first rule for the
  # long-lived dev node). `pending_chunks` becomes the per-source FIFO mailbox
  # that `Ingest.FileIngest.apply/2` consumes one row at a time; the per-source
  # drain boundary that reads it in order lands in the next PR:
  #
  #   * `content_hash` becomes nullable so a **deletion entry** (`status:
  #     "deleted"`, no content) can sit in the same queue as content rows and be
  #     applied in arrival order by the owner — no tombstone table needed. A
  #     CHECK keeps the old invariant for every *other* status: only a
  #     `"deleted"` row may omit the hash, so a content row still can't be
  #     staged without one.
  #   * `attempts`/`last_error`/`retry_after` are the owner's per-row failure
  #     marks: a file that keeps failing is marked and skipped, never blocking
  #     the rest of its source's queue.
  #   * `force` marks a row staged by a forced re-derive (backfill): re-chunk
  #     even when the file's content is unchanged (embeddings are reused).
  #   * `(source_id, id)` index: the owner's drain query is "oldest N rows for
  #     this source, in id order".
  #
  # `chunks.file_hash` records the raw file hash each chunk was derived from,
  # so `FileIngest` can recognise an unchanged file version and skip it. Adding
  # a nullable column is a metadata-only change (no table rewrite), so it stays
  # in this transactional migration. The `chunks` file-identity indexes that
  # back `FileIngest`'s per-file queries live in the FOLLOW-ON migration
  # `20260903120002`, built CONCURRENTLY: a plain `CREATE INDEX` here would take
  # a write lock on the 578k-row `chunks` table for the duration of three index
  # builds, stalling the still-active `UpsertChunks` pipeline. Everything in
  # this migration touches only `pending_chunks` (small, transient staging) or
  # is metadata-only, so it stays online.
  def change do
    alter table(:pending_chunks) do
      modify :content_hash, :text, null: true, from: {:text, null: false}
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :retry_after, :utc_datetime_usec
      add :force, :boolean, null: false, default: false
    end

    create constraint(:pending_chunks, :content_hash_required_unless_deleted,
             check: "content_hash IS NOT NULL OR status = 'deleted'"
           )

    create index(:pending_chunks, [:source_id, :id])

    alter table(:chunks) do
      add :file_hash, :text
    end
  end
end
