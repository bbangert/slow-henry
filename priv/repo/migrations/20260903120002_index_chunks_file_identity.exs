defmodule RetrievalNode.Repo.Migrations.IndexChunksFileIdentity do
  use Ecto.Migration

  # The `chunks` file-identity indexes that back `Ingest.FileIngest`'s per-file
  # queries (unchanged-content skip, embedding-reuse load, chunk-set
  # reconciliation). Each scopes by `source_id` + a LITERAL jsonb identity key
  # (`metadata->>'path'` / `'doc_id'` / `'issue_key'`, one per source type —
  # see `Ingest.file_chunks_query/3`); without them each `apply/2` call would
  # seq-scan every chunk in the source (77.6k files / 578k chunks at corpus
  # scale). `file_hash` trails the identity so the unchanged check is
  # index-only, while reconciliation and the reuse load use the leading
  # `(source_id, identity)` prefix.
  #
  # Built CONCURRENTLY in its own non-transactional migration (the previous
  # migration keeps the existing `UpsertChunks` pipeline live): a plain
  # `CREATE INDEX` would hold a write lock on `chunks` for all three builds and
  # stall live upserts. `concurrently: true` requires both the DDL transaction
  # and Ecto's migration advisory lock to be disabled.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:chunks, [:source_id, "(metadata->>'path')", :file_hash],
             name: :chunks_file_identity_path_idx,
             concurrently: true
           )

    create index(:chunks, [:source_id, "(metadata->>'doc_id')", :file_hash],
             name: :chunks_file_identity_doc_id_idx,
             concurrently: true
           )

    create index(:chunks, [:source_id, "(metadata->>'issue_key')", :file_hash],
             name: :chunks_file_identity_issue_key_idx,
             concurrently: true
           )
  end
end
