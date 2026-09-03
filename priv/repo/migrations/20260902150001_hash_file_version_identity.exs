defmodule RetrievalNode.Repo.Migrations.HashFileVersionIdentity do
  use Ecto.Migration

  @moduledoc false

  # The per-file version claim's unique key was (source_id, identity) with
  # `identity` an unbounded text — a git path (or any identity) past
  # PostgreSQL's ~2.7 KB B-tree index-tuple limit would make every claim for
  # that file fail, and the terminal job would retry into discard. Same
  # failure class as the entities.qualified_name incident. The unique key is
  # now a bounded SHA-256 hex digest of the identity (`identity_hash`, 64
  # chars); `identity` stays as the human-readable value for inspection.
  #
  # Backfills the digest for existing rows in SQL (sha256 over the UTF-8
  # bytes, lowercase hex — the same encoding `Ingest.identity_hash/1` uses),
  # then swaps the unique index.
  #
  # IRREVERSIBLE, deliberately. Two reasons no `down/0` can be honest here:
  # (1) recreating the old (source_id, identity) unique index would fail as
  # soon as any identity past the ~2.7 KB index-tuple limit exists — and
  # accepting those is the whole point of this change; (2) even a bounded
  # substitute key would not satisfy the pre-migration code's
  # `ON CONFLICT (source_id, identity)`, which requires that exact unique
  # index, so a rolled-back schema could not run the old claim anyway.
  def up do
    alter table(:file_versions) do
      add :identity_hash, :string, size: 64, null: true
    end

    execute("""
    UPDATE file_versions
       SET identity_hash = encode(sha256(convert_to(identity, 'UTF8')), 'hex')
    """)

    alter table(:file_versions) do
      modify :identity_hash, :string, size: 64, null: false
    end

    drop unique_index(:file_versions, [:source_id, :identity])
    create unique_index(:file_versions, [:source_id, :identity_hash])
  end

  def down do
    raise Ecto.MigrationError,
          "20260902150001_hash_file_version_identity is irreversible: restoring the " <>
            "unbounded (source_id, identity) unique index fails once any identity exceeds " <>
            "PostgreSQL's index-tuple limit, and the pre-migration claim code requires exactly " <>
            "that index for its ON CONFLICT target — roll forward instead"
  end
end
