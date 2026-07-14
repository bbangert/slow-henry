defmodule RetrievalNode.Ingest.PipelineTest do
  # async: false — starts a (manual-mode) Oban instance and shares the SQL sandbox.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Ingest.Workers.{ChunkFiles, EmbedBatch, UpsertChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, SecretFinding, Source}

  @aws_key "AKIA1234567890ABCDEF"

  setup do
    start_supervised!({Oban, Application.fetch_env!(:retrieval_node, Oban)})
    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    %{source: source}
  end

  defp seed_raw(source, raw_content) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: "repo:acme/app:app.py",
          content_hash: "rawhash-#{System.unique_integer([:positive])}",
          raw_content: raw_content,
          metadata: %{"path" => "app.py"}
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  test "ChunkFiles scrubs, chunks, enqueues EmbedBatch, and reaps the raw row", %{source: source} do
    raw = seed_raw(source, "aws_key = #{@aws_key}\n\ndef hello():\n    return 1\n")

    assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

    # raw row reaped (it held the pre-scrub secret)
    refute Repo.get(PendingChunk, raw.id)

    # chunk rows written, secret redacted, breadcrumb + chunk_key set
    chunks = Repo.all(from p in PendingChunk, where: p.status == "chunked")
    assert chunks != []
    refute Enum.any?(chunks, &String.contains?(&1.chunk_content, @aws_key))
    assert Enum.all?(chunks, &(&1.chunk_key != nil and &1.source_id == source.id))

    # audit row recorded for the redacted secret; EmbedBatch enqueued
    assert Repo.aggregate(SecretFinding, :count, :id) >= 1
    assert_enqueued(worker: EmbedBatch)
  end

  test "full pipeline: ChunkFiles -> EmbedBatch -> UpsertChunks lands permanent chunks", %{
    source: source
  } do
    raw = seed_raw(source, "def a():\n    return 1\n\ndef b():\n    return 2\n")
    assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

    ids = Repo.all(from p in PendingChunk, select: p.id)
    assert :ok = perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})

    # embeddings written, status flipped, UpsertChunks enqueued
    embedded = Repo.all(PendingChunk)
    assert Enum.all?(embedded, &(&1.status == "embedded" and &1.embedding != nil))
    assert_enqueued(worker: UpsertChunks)

    assert :ok = perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})

    # permanent chunks landed; staging drained
    assert Repo.aggregate(PendingChunk, :count, :id) == 0
    chunks = Repo.all(Chunk)
    assert length(chunks) == length(ids)
    assert Enum.all?(chunks, &(&1.source_id == source.id and &1.embedding != nil))
    assert Enum.all?(chunks, &(&1.parse_status == :ok))
  end

  test "UpsertChunks is idempotent — re-running upserts, not duplicates", %{source: source} do
    raw = seed_raw(source, "def a():\n    return 1\n")
    perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})
    ids = Repo.all(from p in PendingChunk, select: p.id)
    perform_job(EmbedBatch, %{"pending_chunk_ids" => ids})
    perform_job(UpsertChunks, %{"pending_chunk_ids" => ids})
    count_after_first = Repo.aggregate(Chunk, :count, :id)

    # Re-ingest the same file → same chunk_key → ON CONFLICT replace.
    raw2 = seed_raw(source, "def a():\n    return 1\n")
    perform_job(ChunkFiles, %{"pending_chunk_id" => raw2.id})
    ids2 = Repo.all(from p in PendingChunk, select: p.id)
    perform_job(EmbedBatch, %{"pending_chunk_ids" => ids2})
    perform_job(UpsertChunks, %{"pending_chunk_ids" => ids2})

    assert Repo.aggregate(Chunk, :count, :id) == count_after_first
  end

  # The scrub `{:cancel, _}` path (unredactable secret / too-large content) must
  # reap the raw row — it still holds the un-redacted secret (review B1).
  test "ChunkFiles reaps the raw row when scrub cancels (fail-closed)", %{source: source} do
    # >5MB trips Scrubber's deterministic {:cancel, :content_too_large}.
    raw = seed_raw(source, String.duplicate("a", 5_000_001))

    assert {:cancel, _} = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

    refute Repo.get(PendingChunk, raw.id)
    assert Repo.all(from p in PendingChunk, where: p.status == "chunked") == []
    refute_enqueued(worker: EmbedBatch)
  end

  describe "ChunkFiles chunker-error branches (fake chunking impl)" do
    setup do
      prev = Application.get_env(:retrieval_node, :chunking_impl)
      Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

      on_exit(fn ->
        Application.put_env(:retrieval_node, :chunking_impl, prev)
        Application.delete_env(:retrieval_node, :fake_chunk_result)
      end)
    end

    defp force_chunk(result), do: Application.put_env(:retrieval_node, :fake_chunk_result, result)

    test "unsupported_language falls back to the heuristic chunker", %{source: source} do
      force_chunk({:error, :unsupported_language})
      raw = seed_raw(source, "def a():\n    return 1\n\ndef b():\n    return 2\n")

      assert :ok = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

      refute Repo.get(PendingChunk, raw.id)
      chunks = Repo.all(from p in PendingChunk, where: p.status == "chunked")
      assert chunks != []
      assert Enum.all?(chunks, &(&1.parse_status == "heuristic_fallback"))
      assert_enqueued(worker: EmbedBatch)
    end

    for err <- [:too_large, :binary_content] do
      test "#{err} is skipped (cancel) and the raw row reaped", %{source: source} do
        force_chunk({:error, unquote(err)})
        raw = seed_raw(source, "def a():\n    return 1\n")

        assert {:cancel, _} = perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id})

        refute Repo.get(PendingChunk, raw.id)
        assert Repo.all(from p in PendingChunk, where: p.status == "chunked") == []
        refute_enqueued(worker: EmbedBatch)
      end
    end

    test "a parse crash on the FINAL attempt falls back to heuristic", %{source: source} do
      force_chunk({:error, :chunk_crashed})
      raw = seed_raw(source, "def a():\n    return 1\n")

      assert :ok =
               perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id},
                 attempt: 5,
                 max_attempts: 5
               )

      refute Repo.get(PendingChunk, raw.id)
      chunks = Repo.all(from p in PendingChunk, where: p.status == "chunked")
      assert chunks != []
      assert Enum.all?(chunks, &(&1.parse_status == "crashed_fallback"))
    end

    test "a parse crash before the final attempt errors (retryable), keeping the raw row", %{
      source: source
    } do
      force_chunk({:error, :chunk_crashed})
      raw = seed_raw(source, "def a():\n    return 1\n")

      assert {:error, :chunk_crashed} =
               perform_job(ChunkFiles, %{"pending_chunk_id" => raw.id},
                 attempt: 1,
                 max_attempts: 5
               )

      # not reaped — a later retry can still succeed
      assert Repo.get(PendingChunk, raw.id)
      assert Repo.all(from p in PendingChunk, where: p.status == "chunked") == []
    end
  end
end
