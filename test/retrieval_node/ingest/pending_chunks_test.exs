defmodule RetrievalNode.Ingest.PendingChunksTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.PendingChunk

  defp raw_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        source: "git",
        source_id: Ecto.UUID.generate(),
        source_type: "git_repo",
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

  test "insert_raw_all bulk-inserts in a single round-trip and returns the ids" do
    assert {:ok, ids} = PendingChunks.insert_raw_all([raw_attrs(), raw_attrs()])
    assert length(ids) == 2
    assert Repo.aggregate(PendingChunk, :count, :id) == 2
  end

  test "insert_raw_all is atomic — a NOT NULL violation aborts the whole batch" do
    assert_raise Postgrex.Error, fn ->
      PendingChunks.insert_raw_all([raw_attrs(), raw_attrs(%{natural_key: nil})])
    end

    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "insert_raw_all skips a row whose raw_content has a NUL byte (never reaches Postgres)" do
    good = raw_attrs()

    binary =
      raw_attrs(%{natural_key: "repo:acme/app:favicon.ico", raw_content: <<0, 255, 216, 0>>})

    assert {:ok, ids} = PendingChunks.insert_raw_all([good, binary])

    assert length(ids) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 1
    assert Repo.one!(PendingChunk).natural_key == good.natural_key
  end

  test "insert_raw_all skips invalid-UTF-8 content even without a NUL byte" do
    good = raw_attrs()

    invalid =
      raw_attrs(%{natural_key: "repo:acme/app:mystery.bin", raw_content: <<255, 254>> <> "text"})

    assert {:ok, ids} = PendingChunks.insert_raw_all([good, invalid])

    assert length(ids) == 1
    assert Repo.aggregate(PendingChunk, :count, :id) == 1
    assert Repo.one!(PendingChunk).natural_key == good.natural_key
  end

  test "insert_raw_all skipping every row is a no-op insert, not an error" do
    binary = raw_attrs(%{raw_content: <<0, 1, 2>>})

    assert {:ok, []} = PendingChunks.insert_raw_all([binary])
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "insert_raw_all batches >2,000 rows at the real default batch size, preserving id order" do
    # Regression for the Postgres 65,535-bind-parameter ceiling (issue #9): a
    # single insert_all over ~12 params/row tops out around ~5,400 rows. 2,500
    # rows forces the real default batch size (2,000) to split into two actual
    # `insert_all` round-trips — no config override needed to hit that path.
    rows = for i <- 1..2_500, do: raw_attrs(%{natural_key: "repo:acme/app:file#{i}.ex"})

    assert {:ok, ids} = PendingChunks.insert_raw_all(rows)
    assert length(ids) == 2_500
    assert Repo.aggregate(PendingChunk, :count, :id) == 2_500

    # ids must come back in the same order as the input rows — batch
    # concatenation must not reorder or interleave.
    natural_key_by_id = Repo.all(PendingChunk) |> Map.new(&{&1.id, &1.natural_key})

    assert Enum.map(ids, &natural_key_by_id[&1]) ==
             Enum.map(1..2_500, &"repo:acme/app:file#{&1}.ex")
  end

  test "insert_raw_all's binary-content guard still applies across a batch boundary" do
    # Binary rows placed just before and just after the real default batch
    # boundary (2,000) prove the guard runs on the FULL set before chunking,
    # not per-batch — with no global config mutation, so the module can stay
    # async: true.
    binary_at = MapSet.new([1_999, 2_001])

    rows =
      for i <- 1..2_005 do
        if i in binary_at do
          raw_attrs(%{natural_key: "repo:acme/app:bin#{i}.ico", raw_content: <<0, 1, 2>>})
        else
          raw_attrs(%{natural_key: "repo:acme/app:file#{i}.ex"})
        end
      end

    assert {:ok, ids} = PendingChunks.insert_raw_all(rows)
    assert length(ids) == 2_003
    assert Repo.aggregate(PendingChunk, :count, :id) == 2_003
    refute Repo.get_by(PendingChunk, natural_key: "repo:acme/app:bin1999.ico")
    refute Repo.get_by(PendingChunk, natural_key: "repo:acme/app:bin2001.ico")

    natural_key_by_id = Repo.all(PendingChunk) |> Map.new(&{&1.id, &1.natural_key})
    expected = for i <- 1..2_005, i not in binary_at, do: "repo:acme/app:file#{i}.ex"
    assert Enum.map(ids, &natural_key_by_id[&1]) == expected
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
    assert {:ok, :ok} = PendingChunks.set_embeddings([%{id: chunk.id, embedding: vector}])

    reloaded = PendingChunks.fetch!(chunk.id)
    assert reloaded.status == "embedded"

    round_tripped = Pgvector.to_list(reloaded.embedding)
    assert length(round_tripped) == 384
    # vector(384) stores float32, so compare within tolerance.
    assert Enum.zip(round_tripped, vector) |> Enum.all?(fn {a, b} -> abs(a - b) < 1.0e-4 end)
  end

  test "set_embeddings rolls back if an id doesn't exist (no silent drop)" do
    vector = for _ <- 1..384, do: 0.0

    assert {:error, {:no_such_pending_chunk, 999_999}} =
             PendingChunks.set_embeddings([%{id: 999_999, embedding: vector}])
  end

  test "fetch_many! and delete_by_ids operate on a set of ids" do
    {:ok, a} = PendingChunks.insert_raw(raw_attrs())
    {:ok, b} = PendingChunks.insert_raw(raw_attrs())

    assert length(PendingChunks.fetch_many!([a.id, b.id])) == 2
    assert {2, nil} = PendingChunks.delete_by_ids([a.id, b.id])
    assert PendingChunks.fetch_many!([a.id, b.id]) == []
  end
end
