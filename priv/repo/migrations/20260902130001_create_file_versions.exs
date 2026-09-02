defmodule RetrievalNode.Repo.Migrations.CreateFileVersions do
  use Ecto.Migration

  @moduledoc false

  # First-class file identity + atomic version claim for the ingest pipeline.
  #
  # The pipeline's unit of work is a per-stage Oban job, not a file: two
  # versions of one file can be in flight concurrently (retries, an hours-deep
  # embed backlog), and any per-file invariant — "the persisted chunk set is
  # the latest version's set" — needs a serialization point the pipeline never
  # had. Advisory locks or a max(generation) scan over `chunks` patch that
  # non-atomically; this table gives the file a row, and the terminal stage
  # opens its transaction with
  #
  #     UPDATE file_versions SET generation = $new
  #      WHERE source_id = $s AND identity = $i AND generation < $new
  #      RETURNING id
  #
  # so the row lock serializes concurrent terminal jobs for the same file and
  # 0 rows == "a newer version already landed — skip". Multi-node safe (the
  # lock lives in Postgres), no hash collisions, inspectable.
  #
  # `identity` is the per-source-type file identity value already used by the
  # sync workers' deletion paths (git: metadata path; drive: doc_id; jira:
  # issue_key). `generation` is the raw pending_chunks row id of the version
  # (bigserial ⇒ monotonic). Rows are created on first claim; cascade with
  # their source.
  def change do
    create table(:file_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :identity, :text, null: false
      add :generation, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:file_versions, [:source_id, :identity])
  end
end
