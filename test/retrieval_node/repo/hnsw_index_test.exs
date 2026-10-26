defmodule RetrievalNode.Repo.HnswIndexTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Repo

  test "chunks_embedding_hnsw_idx is valid and built with m = 32, ef_construction = 200" do
    %{rows: [[indexdef, valid?]]} =
      Repo.query!("""
      SELECT pg_get_indexdef(i.indexrelid), i.indisvalid
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'chunks_embedding_hnsw_idx'
      """)

    assert valid?
    assert indexdef =~ "m='32'"
    assert indexdef =~ "ef_construction='200'"
  end

  test "no temporary rebuild index is left behind" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE indexname LIKE 'chunks_embedding_hnsw_m%'"
      )

    assert rows == []
  end
end
