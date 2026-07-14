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
end
