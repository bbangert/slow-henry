defmodule RetrievalNode.Repo.Migrations.DropIngestMachinery do
  use Ecto.Migration

  @moduledoc false

  # Phase 3 cutover, LAST step. Drops the compensating machinery the
  # ingest-serialization redesign replaced with the `Ingest.SourceOwner`
  # boundary + `Ingest.FileIngest` functional core:
  #
  #   * `file_versions` — the atomic per-file claim table
  #     (`Ingest.claim_file_version/4`), superseded by the owner's mailbox
  #     serialization (its GenServer processes one row at a time per source,
  #     by construction — no DB-side claim needed).
  #   * `chunks.ingest_generation` / `pending_chunks.ingest_generation` — the
  #     provenance column threaded through the claim; no longer written.
  #   * `pending_chunks`' staging-stage columns (`chunk_index`,
  #     `chunk_content`, `chunk_key`, `context_breadcrumb`, `parse_status`,
  #     `secrets_status`, `embedding`, `graph`, `scrub_mode`,
  #     `chunk_quality`) — these existed to carry a raw row's split-out state
  #     between the deleted `ChunkFiles` -> `EmbedBatch` -> `UpsertChunks`
  #     Oban stages. `Ingest.FileIngest.apply/2` does scrub -> chunk -> embed
  #     -> write in one function call against one raw row, so the mailbox row
  #     (`pending_chunks`) needs none of them.
  #
  # This is LAST (after `lib/mix/tasks/rn.graph.backfill.ex`, the deleted
  # workers, and every other Phase 3 code change have landed and the running
  # node has already been restarted onto that code) because the running node
  # must no longer reference any of these before they're gone — the
  # dev-node hot-code-reload rule (`config/*.exs` changes, and by extension
  # a destructive schema change like this one, need a node restart) is what
  # makes "code first, schema last" safe here rather than a race.
  #
  # `down/0` restores the schema SHAPE (same types/defaults/null-ness as the
  # original migrations), not the data — the dropped columns/table are gone
  # for good; a rollback gets empty structure to grow into again, not a
  # restored backfill.

  def up do
    drop table(:file_versions)

    alter table(:chunks) do
      remove :ingest_generation
    end

    alter table(:pending_chunks) do
      remove :ingest_generation
      remove :chunk_index
      remove :chunk_content
      remove :chunk_key
      remove :context_breadcrumb
      remove :parse_status
      remove :secrets_status
      remove :embedding
      remove :graph
      remove :scrub_mode
      remove :chunk_quality
    end
  end

  def down do
    alter table(:pending_chunks) do
      add :chunk_index, :integer
      add :chunk_content, :text
      add :chunk_key, :string
      add :context_breadcrumb, :text
      add :parse_status, :string, null: false, default: "ok"
      add :secrets_status, :string, null: false, default: "clean"
      add :embedding, :vector, size: 384
      add :graph, :map, null: false, default: %{}
      add :scrub_mode, :text
      add :chunk_quality, :text
      add :ingest_generation, :bigint, null: true
    end

    alter table(:chunks) do
      add :ingest_generation, :bigint, null: true
    end

    create table(:file_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :identity, :text, null: false
      add :identity_hash, :string, size: 64, null: false
      add :generation, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:file_versions, [:source_id, :identity_hash])
  end
end
