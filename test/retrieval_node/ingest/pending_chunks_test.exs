defmodule RetrievalNode.Ingest.PendingChunksTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Ingest.{PendingChunks, SourceOwner}
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

  test "insert_raw carries :force through the single-row changeset" do
    assert {:ok, row} = PendingChunks.insert_raw(raw_attrs(%{force: true}))
    assert row.force == true
    assert PendingChunks.fetch!(row.id).force == true
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

  test "the content_hash CHECK rejects a raw row with no hash (only 'deleted' may omit it)" do
    # content_hash is nullable now (deletion entries carry none), but the
    # migration's CHECK keeps the old invariant for content rows — insert_all
    # bypasses the changeset, so the DB is the last line of defence against a
    # hash-less raw row poisoning staging.
    assert_raise Postgrex.Error, ~r/content_hash_required_unless_deleted/, fn ->
      PendingChunks.insert_raw_all([raw_attrs(%{content_hash: nil})])
    end

    assert Repo.aggregate(PendingChunk, :count, :id) == 0
  end

  test "a 'deleted' row is allowed to omit content_hash" do
    deletion = raw_attrs(%{status: "deleted", content_hash: nil, raw_content: nil})
    assert {:ok, [_id]} = PendingChunks.insert_raw_all([deletion])
    assert Repo.aggregate(PendingChunk, :count, :id) == 1
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

  test "delete_by_ids operates on a set of ids" do
    {:ok, a} = PendingChunks.insert_raw(raw_attrs())
    {:ok, b} = PendingChunks.insert_raw(raw_attrs())

    assert {2, nil} = PendingChunks.delete_by_ids([a.id, b.id])
    refute Repo.get(PendingChunk, a.id)
    refute Repo.get(PendingChunk, b.id)
  end

  # --- Ingest.SourceOwner's mailbox reads ------------------------------------

  describe "drainable/2 and drainable?/1" do
    test "returns raw and deleted rows for the source, oldest first, excludes other sources" do
      source_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()

      {:ok, [id1]} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_id})])
      {:ok, [id2]} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_id})])

      {:ok, [id3]} =
        PendingChunks.insert_raw_all([
          raw_attrs(%{
            source_id: source_id,
            status: "deleted",
            content_hash: nil,
            raw_content: nil
          })
        ])

      {:ok, _} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: other_id})])

      rows = PendingChunks.drainable(source_id)
      assert Enum.map(rows, & &1.id) == [id1, id2, id3]
      assert Enum.all?(rows, &(&1.source_id == source_id))

      assert PendingChunks.drainable?(source_id)
      refute PendingChunks.drainable?(Ecto.UUID.generate())
    end

    test "limit: N bounds the result to the oldest N rows" do
      source_id = Ecto.UUID.generate()

      ids =
        for i <- 1..5 do
          {:ok, [id]} =
            PendingChunks.insert_raw_all([
              raw_attrs(%{source_id: source_id, natural_key: "repo:x:f#{i}.ex"})
            ])

          id
        end

      rows = PendingChunks.drainable(source_id, limit: 2)
      assert Enum.map(rows, & &1.id) == Enum.take(ids, 2)
    end

    test "excludes a row past max_file_attempts, and one still in its retry_after backoff window" do
      source_id = Ecto.UUID.generate()
      {:ok, [maxed_id]} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_id})])
      {:ok, [backed_off_id]} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_id})])
      {:ok, [ready_id]} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_id})])

      Repo.update_all(PendingChunks.by_ids([maxed_id]),
        set: [attempts: SourceOwner.max_file_attempts()]
      )

      Repo.update_all(PendingChunks.by_ids([backed_off_id]),
        set: [retry_after: DateTime.add(DateTime.utc_now(), 3600, :second)]
      )

      assert Enum.map(PendingChunks.drainable(source_id), & &1.id) == [ready_id]
    end
  end

  describe "pending_source_ids/0" do
    test "returns distinct source_ids with at least one drainable row" do
      source_a = Ecto.UUID.generate()
      source_b = Ecto.UUID.generate()
      maxed_out_source = Ecto.UUID.generate()

      {:ok, _} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_a})])
      {:ok, _} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_a})])
      {:ok, _} = PendingChunks.insert_raw_all([raw_attrs(%{source_id: source_b})])

      {:ok, [maxed_id]} =
        PendingChunks.insert_raw_all([raw_attrs(%{source_id: maxed_out_source})])

      Repo.update_all(PendingChunks.by_ids([maxed_id]),
        set: [attempts: SourceOwner.max_file_attempts()]
      )

      ids = PendingChunks.pending_source_ids()
      assert source_a in ids
      assert source_b in ids
      refute maxed_out_source in ids
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "mark_attempt/1 and mark_failure/3" do
    test "mark_attempt increments attempts and returns the updated row" do
      {:ok, row} = PendingChunks.insert_raw(raw_attrs())
      assert row.attempts == 0

      updated = PendingChunks.mark_attempt(row)
      assert updated.attempts == 1

      updated2 = PendingChunks.mark_attempt(updated)
      assert updated2.attempts == 2
    end

    test "mark_failure sets last_error and retry_after without touching attempts" do
      {:ok, row} = PendingChunks.insert_raw(raw_attrs())
      row = PendingChunks.mark_attempt(row)

      retry_after = DateTime.add(DateTime.utc_now(), 120, :second)
      assert :ok = PendingChunks.mark_failure(row, {:boom, :reason}, retry_after)

      reloaded = PendingChunks.fetch!(row.id)
      assert reloaded.last_error =~ "boom"
      assert reloaded.attempts == 1
      assert DateTime.compare(reloaded.retry_after, DateTime.utc_now()) == :gt
    end

    test "mark_failure truncates a very long reason to a diagnostic-length excerpt" do
      {:ok, row} = PendingChunks.insert_raw(raw_attrs())
      long_reason = String.duplicate("x", 10_000)

      assert :ok = PendingChunks.mark_failure(row, long_reason, DateTime.utc_now())

      reloaded = PendingChunks.fetch!(row.id)
      assert byte_size(reloaded.last_error) <= 2_000
    end
  end

  describe "failed_count/0" do
    test "counts only rows at or past max_file_attempts" do
      {:ok, [under_id]} = PendingChunks.insert_raw_all([raw_attrs()])
      {:ok, [at_id]} = PendingChunks.insert_raw_all([raw_attrs()])

      Repo.update_all(PendingChunks.by_ids([under_id]),
        set: [attempts: SourceOwner.max_file_attempts() - 1]
      )

      Repo.update_all(PendingChunks.by_ids([at_id]),
        set: [attempts: SourceOwner.max_file_attempts()]
      )

      assert PendingChunks.failed_count() == 1
    end
  end
end
