defmodule RetrievalNode.Repo.Migrations.AddChunkProvenanceToEntityEdges do
  use Ecto.Migration

  # `change/0`'s implicit down would recreate the old (source_entity_id,
  # target_entity_id, kind) unique index verbatim — which fails the moment
  # this migration has been up long enough for multiple chunk-provenance rows
  # to exist per logical edge (see EntityEdge's moduledoc: one row per
  # contributing chunk is the whole point of this migration). Explicit up/0 +
  # down/0 instead, so down/0 can consolidate those rows back into one per
  # triple before the triple-unique index is restored.
  def up do
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

    execute("""
    COMMENT ON COLUMN entity_edges.chunk_id IS
    'Chunk-level provenance: keys each file''s contribution to a merged entity''s edges by its own chunks, so per-file re-derivation does not clobber another file''s contribution, and gives edges the same FK-cascade deletion lifecycle as entity_mentions. NULL for legacy rows that predate provenance, handled by a transitional delete in Graph.write_edges/4 until organically replaced.'
    """)
  end

  def down do
    # Consolidate BEFORE dropping chunk_id and restoring the triple unique
    # index: once this migration has been up, entity_edges can legitimately
    # hold several rows per (source_entity_id, target_entity_id, kind) —
    # one per contributing chunk — which the pre-provenance triple unique
    # index can't hold at all. Collapse each triple down to a single row
    # first, or `create unique_index` below fails on the first duplicate
    # triple it finds.
    #
    # weight is additive (each row's weight is a mention count contributed by
    # its own chunk), so the consolidated row's weight is the SUM across the
    # triple's rows. Which row survives is otherwise arbitrary — there's no
    # "correct" chunk to prefer once provenance is being removed — so the
    # keeper is picked deterministically by MIN(id::text) rather than by
    # insertion order or any other implicit tiebreak, so this is
    # reproducible if run twice against the same data.
    execute("""
    WITH totals AS (
      SELECT source_entity_id, target_entity_id, kind,
             SUM(weight) AS total_weight,
             MIN(id::text) AS keeper_id
      FROM entity_edges
      GROUP BY source_entity_id, target_entity_id, kind
    )
    UPDATE entity_edges e
    SET weight = t.total_weight
    FROM totals t
    WHERE e.id::text = t.keeper_id
      AND e.source_entity_id = t.source_entity_id
      AND e.target_entity_id = t.target_entity_id
      AND e.kind = t.kind
    """)

    execute("""
    WITH totals AS (
      SELECT source_entity_id, target_entity_id, kind, MIN(id::text) AS keeper_id
      FROM entity_edges
      GROUP BY source_entity_id, target_entity_id, kind
    )
    DELETE FROM entity_edges e
    USING totals t
    WHERE e.source_entity_id = t.source_entity_id
      AND e.target_entity_id = t.target_entity_id
      AND e.kind = t.kind
      AND e.id::text <> t.keeper_id
    """)

    drop index(:entity_edges, [:chunk_id])

    drop unique_index(
           :entity_edges,
           [:source_entity_id, :target_entity_id, :kind, :chunk_id],
           name: :entity_edges_source_target_kind_chunk_index
         )

    alter table(:entity_edges) do
      remove :chunk_id
    end

    create unique_index(:entity_edges, [:source_entity_id, :target_entity_id, :kind])
  end
end
