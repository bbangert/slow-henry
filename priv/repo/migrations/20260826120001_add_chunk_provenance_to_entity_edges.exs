defmodule RetrievalNode.Repo.Migrations.AddChunkProvenanceToEntityEdges do
  use Ecto.Migration

  def change do
    alter table(:entity_edges) do
      # Nullable: legacy rows written before this migration predate
      # provenance and keep chunk_id NULL — Graph.write_edges/4 handles them
      # with a transitional delete until every such row is organically
      # replaced by a chunk-scoped re-ingest (see that function's comment).
      add :chunk_id, references(:chunks, type: :binary_id, on_delete: :delete_all)
    end

    # Replaces the old (source_entity_id, target_entity_id, kind) unique
    # index: entities deliberately merge one qualified_name across every
    # file of a source, so two files contributing outgoing edges for the
    # same merged entity must be able to hold distinct rows for the same
    # (source, target, kind) triple — one per contributing chunk — instead
    # of colliding on ON CONFLICT and clobbering each other.
    drop unique_index(:entity_edges, [:source_entity_id, :target_entity_id, :kind])

    create unique_index(
             :entity_edges,
             [:source_entity_id, :target_entity_id, :kind, :chunk_id],
             name: :entity_edges_source_target_kind_chunk_index
           )

    create index(:entity_edges, [:chunk_id])

    execute(
      """
      COMMENT ON COLUMN entity_edges.chunk_id IS
      'Chunk-level provenance: keys each file''s contribution to a merged entity''s edges by its own chunks, so per-file re-derivation does not clobber another file''s contribution, and gives edges the same FK-cascade deletion lifecycle as entity_mentions. NULL for legacy rows that predate provenance, handled by a transitional delete in Graph.write_edges/4 until organically replaced.'
      """,
      "COMMENT ON COLUMN entity_edges.chunk_id IS NULL"
    )
  end
end
