defmodule RetrievalNode.Ingest.PendingChunksTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.PendingChunk

  defp raw_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        source: "git",
        natural_key: "repo:acme/app:lib/foo.ex",
        content_hash: "hash-#{System.unique_integer([:positive])}",
        raw_content: "def foo, do: :ok"
      },
      overrides
    )
  end

  test "insert_raw persists a row with status raw" do
    assert {:ok, row} = PendingChunks.insert_raw(raw_attrs())
    assert row.status == "raw"
    assert PendingChunks.fetch!(row.id).natural_key == "repo:acme/app:lib/foo.ex"
  end

  test "insert_raw_all bulk-inserts in a single round-trip" do
    assert {:ok, 2} = PendingChunks.insert_raw_all([raw_attrs(), raw_attrs()])
    assert Repo.aggregate(PendingChunk, :count) == 2
  end

  test "insert_raw_all is atomic — a NOT NULL violation aborts the whole batch" do
    assert_raise Postgrex.Error, fn ->
      PendingChunks.insert_raw_all([raw_attrs(), raw_attrs(%{natural_key: nil})])
    end

    assert Repo.aggregate(PendingChunk, :count) == 0
  end

  test "write_chunks splits a raw row into N chunk rows sharing natural_key/content_hash" do
    {:ok, raw} = PendingChunks.insert_raw(raw_attrs())

    chunks = [
      %{chunk_index: 0, chunk_content: "chunk zero"},
      %{chunk_index: 1, chunk_content: "chunk one"}
    ]

    assert {:ok, [c0, c1]} =
             PendingChunks.write_chunks(raw, chunks,
               chunk_quality: "tree_sitter",
               scrub_mode: "regex"
             )

    assert c0.natural_key == raw.natural_key
    assert c0.content_hash == raw.content_hash
    assert c0.chunk_quality == "tree_sitter"
    assert c0.status == "chunked"
    assert Enum.sort([c0.chunk_index, c1.chunk_index]) == [0, 1]
  end

  test "set_embeddings writes 384-dim vectors back and flips status to embedded" do
    {:ok, raw} = PendingChunks.insert_raw(raw_attrs())
    {:ok, [chunk]} = PendingChunks.write_chunks(raw, [%{chunk_index: 0, chunk_content: "x"}])

    # Distinct per-dimension values so a transposed/garbled write would be caught.
    vector = for i <- 1..384, do: i * 0.001
    assert :ok = PendingChunks.set_embeddings([%{id: chunk.id, embedding: vector}])

    reloaded = PendingChunks.fetch!(chunk.id)
    assert reloaded.status == "embedded"

    round_tripped = Pgvector.to_list(reloaded.embedding)
    assert length(round_tripped) == 384
    # vector(384) stores float32, so compare within tolerance.
    assert Enum.zip(round_tripped, vector) |> Enum.all?(fn {a, b} -> abs(a - b) < 1.0e-4 end)
  end

  test "fetch_many! and delete_by_ids operate on a set of ids" do
    {:ok, a} = PendingChunks.insert_raw(raw_attrs())
    {:ok, b} = PendingChunks.insert_raw(raw_attrs())

    assert length(PendingChunks.fetch_many!([a.id, b.id])) == 2
    assert {2, nil} = PendingChunks.delete_by_ids([a.id, b.id])
    assert PendingChunks.fetch_many!([a.id, b.id]) == []
  end
end
