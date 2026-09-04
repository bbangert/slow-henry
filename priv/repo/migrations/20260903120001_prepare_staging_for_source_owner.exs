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
  # so `FileIngest` can recognise an unchanged file version and skip it entirely.
  # The three `chunks` expression indexes back `FileIngest`'s per-file queries
  # (unchanged-content skip, embedding-reuse load, chunk-set reconciliation),
  # which all scope by `source_id` + a LITERAL jsonb identity key
  # (`metadata->>'path'` / `'doc_id'` / `'issue_key'`, one per source type —
  # see `Ingest.file_chunks_query/3`). Without them each `apply/2` call would
  # seq-scan every chunk in the source (77.6k files / 578k chunks at corpus
  # scale). `file_hash` trails the identity in the index so the unchanged
  # check is index-only; reconciliation and the reuse load use the leading
  # `(source_id, identity)` prefix.
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

    create index(:chunks, [:source_id, "(metadata->>'path')", :file_hash],
             name: :chunks_file_identity_path_idx
           )

    create index(:chunks, [:source_id, "(metadata->>'doc_id')", :file_hash],
             name: :chunks_file_identity_doc_id_idx
           )

    create index(:chunks, [:source_id, "(metadata->>'issue_key')", :file_hash],
             name: :chunks_file_identity_issue_key_idx
           )
  end
end
