defmodule RetrievalNode.Bench.RerankEvalTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Bench.RerankEval
  alias RetrievalNode.Retrieval.{Chunk, Source}

  defp source_fixture(identifier) do
    Repo.insert!(%Source{source_type: :git_repo, name: identifier, identifier: identifier})
  end

  defp chunk_fixture(source, attrs) do
    defaults = %{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "hash-#{System.unique_integer([:positive])}",
      content: "placeholder chunk content",
      context_breadcrumb: "lib/foo.ex",
      metadata: %{},
      embedding: for(_ <- 1..384, do: 0.0)
    }

    attrs =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Map.update!(:embedding, &Pgvector.new/1)

    Repo.insert!(struct(Chunk, attrs))
  end

  defp write_queries!(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rerank_eval_queries_#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "reranking_ready?/0" do
    test "is true for the test-env StubImpl (no warmup concept)" do
      assert RerankEval.reranking_ready?()
    end
  end

  describe "run/1" do
    test "reports both modes' aggregates and per-query rows, excluding unresolved queries" do
      source = source_fixture("repo-a")

      _chunk =
        chunk_fixture(source,
          repo: "repo-a",
          content: "the quick brown fox jumps over the lazy dog",
          context_breadcrumb: "lib/foo.ex",
          metadata: %{"path" => "lib/foo.ex"}
        )

      path =
        write_queries!([
          %{
            "query" => "quick brown fox",
            "relevant" => [%{"repo" => "repo-a", "path_prefix" => "lib/foo.ex"}]
          },
          %{
            "query" => "no such thing anywhere",
            "relevant" => [%{"path_prefix" => "lib/does_not_exist.ex"}]
          }
        ])

      assert {:ok, result} = RerankEval.run(queries_path: path, top_k: 5)

      assert result.queries_total == 2
      assert result.queries_resolved == 1
      assert result.queries_unresolved == 1
      assert result.top_k == 5

      assert %{false => baseline, true => reranked} = result.modes

      for mode <- [baseline, reranked] do
        assert is_float(mode.mean_mrr)
        assert mode.mean_mrr >= 0.0 and mode.mean_mrr <= 1.0
        assert is_float(mode.hit_at_1_rate)
        assert is_float(mode.hit_at_5_rate)
        assert %{50 => p50, 95 => _} = mode.latency_ms_percentiles
        assert is_number(p50)
      end

      assert length(result.per_query) == 2

      resolvable_row = Enum.find(result.per_query, & &1.resolvable)
      unresolvable_row = Enum.find(result.per_query, &(not &1.resolvable))

      assert resolvable_row.query == "quick brown fox"
      assert %{false => %{mrr: _, first_relevant_rank: _, latency_ms: _}} = resolvable_row.modes

      assert unresolvable_row.query == "no such thing anywhere"
      assert unresolvable_row.modes == %{}
    end

    test "skips when the corpus is empty" do
      path = write_queries!([%{"query" => "q", "relevant" => [%{"repo" => "r"}]}])

      assert {:skipped, reason} = RerankEval.run(queries_path: path)
      assert reason =~ "corpus not seeded"
    end

    test "top_k is normalized once via HybridQuery.clamp_top_k/1 and the NORMALIZED value is reported" do
      source = source_fixture("repo-b")
      _chunk = chunk_fixture(source, repo: "repo-b")
      path = write_queries!([%{"query" => "q", "relevant" => [%{"repo" => "repo-b"}]}])

      # Above the clamp's max (100) -> reported as the clamped max, not the
      # raw 1_000 that was passed in.
      assert {:ok, %{top_k: 100}} = RerankEval.run(queries_path: path, top_k: 1_000)

      # Not a positive integer -> clamp_top_k/1 falls back to its own
      # default (20), not RerankEval's own default (10) and not "0".
      assert {:ok, %{top_k: 20}} = RerankEval.run(queries_path: path, top_k: 0)
    end
  end
end
