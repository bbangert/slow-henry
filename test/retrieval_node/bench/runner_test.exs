defmodule RetrievalNode.Bench.RunnerTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Bench.Runner
  alias RetrievalNode.Retrieval.{Chunk, Source}

  @dim 384

  defp axis(i) do
    for j <- 0..(@dim - 1), do: if(j == i, do: 1.0, else: 0.0)
  end

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
      embedding: axis(0)
    }

    attrs =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Map.update!(:embedding, &Pgvector.new/1)

    Repo.insert!(struct(Chunk, attrs))
  end

  defp write_queries!(lines) do
    path =
      Path.join(System.tmp_dir!(), "bench_queries_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "load_queries!/1" do
    test "parses a valid JSONL file into a list of maps" do
      path =
        write_queries!([
          %{"query" => "where is X", "relevant" => [%{"repo" => "r"}], "note" => "n"}
        ])

      assert [%{"query" => "where is X", "relevant" => [%{"repo" => "r"}]}] =
               Runner.load_queries!(path)
    end

    test "raises when a query is missing required keys" do
      path = write_queries!([%{"query" => "no relevant key"}])

      assert_raise ArgumentError, ~r/missing required/, fn -> Runner.load_queries!(path) end
    end

    test "raises when a matcher has none of the recognized keys" do
      path =
        write_queries!([
          %{"query" => "q", "relevant" => [%{"totally_unrecognized" => "x"}]}
        ])

      assert_raise ArgumentError, ~r/refusing to run it/, fn -> Runner.load_queries!(path) end
    end
  end

  describe "resolve_relevant_ids/1" do
    test "AND's fields within a single matcher" do
      source = source_fixture("repo-a")

      both =
        chunk_fixture(source,
          repo: "repo-a",
          metadata: %{"path" => "lib/foo.ex"},
          context_breadcrumb: "lib/foo.ex"
        )

      wrong_repo =
        chunk_fixture(source,
          repo: "repo-b",
          metadata: %{"path" => "lib/foo.ex"},
          context_breadcrumb: "lib/foo.ex"
        )

      ids = Runner.resolve_relevant_ids([%{"repo" => "repo-a", "path_prefix" => "lib/foo.ex"}])

      assert ids == MapSet.new([both.id])
      refute wrong_repo.id in ids
    end

    test "OR's across multiple matchers in the list" do
      source = source_fixture("repo-a")

      a =
        chunk_fixture(source,
          repo: "repo-a",
          metadata: %{"path" => "lib/a.ex"},
          context_breadcrumb: "lib/a.ex"
        )

      b =
        chunk_fixture(source,
          repo: "repo-a",
          metadata: %{"path" => "lib/b.ex"},
          context_breadcrumb: "lib/b.ex"
        )

      ids =
        Runner.resolve_relevant_ids([
          %{"path_prefix" => "lib/a.ex"},
          %{"path_prefix" => "lib/b.ex"}
        ])

      assert ids == MapSet.new([a.id, b.id])
    end

    test "path_prefix matches as a prefix, not a suffix or substring" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/foo/bar.ex"})

      _no_match =
        chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/other/foo/bar.ex"})

      ids = Runner.resolve_relevant_ids([%{"path_prefix" => "lib/foo"}])

      assert ids == MapSet.new([match.id])
    end

    test "escapes LIKE metacharacters in path_prefix so a literal underscore doesn't wildcard" do
      source = source_fixture("repo-a")

      literal =
        chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/nx_serving_impl.ex"})

      decoy =
        chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/nxXservingXimpl.ex"})

      ids = Runner.resolve_relevant_ids([%{"path_prefix" => "lib/nx_serving_impl.ex"}])

      assert ids == MapSet.new([literal.id])
      refute decoy.id in ids
    end

    test "breadcrumb_substring matches case-insensitively anywhere in the breadcrumb" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source, repo: "repo-a", context_breadcrumb: "lib/foo.ex > Foo > BAR/1")

      ids = Runner.resolve_relevant_ids([%{"breadcrumb_substring" => "foo > bar"}])

      assert ids == MapSet.new([match.id])
    end
  end

  describe "corpus_seeded?/0 and embedding_ready?/0" do
    test "corpus_seeded? reflects whether any chunks exist" do
      refute Runner.corpus_seeded?()

      source = source_fixture("repo-a")
      chunk_fixture(source, repo: "repo-a")

      assert Runner.corpus_seeded?()
    end

    test "embedding_ready? is true for the test-env StubImpl (no warmup concept)" do
      assert Runner.embedding_ready?()
    end
  end

  describe "run/1 end-to-end (StubImpl, no real model)" do
    test "quality runs against a seeded corpus; matryoshka skips (StubImpl has no truncation)" do
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
          }
        ])

      result = Runner.run(queries_path: path, top_k: 5, skip_embed_probe: true)

      assert result.queries_loaded == 1

      assert {:ok, quality} = result.quality
      assert quality.queries_total == 1
      assert quality.queries_resolved == 1
      assert quality.queries_unresolved == 0
      assert is_float(quality.mean_ndcg_at_k)
      assert quality.mean_ndcg_at_k >= 0.0 and quality.mean_ndcg_at_k <= 1.0
      assert %{50 => p50, 95 => _, 99 => _} = quality.latency_ms_percentiles
      assert is_number(p50)

      assert result.embed_probe == {:skipped, "--skip-embed-probe passed"}

      assert {:skipped, reason} = result.matryoshka
      assert reason =~ "NxServingImpl"
    end

    test "queries with no matcher hits in the corpus are excluded from the aggregate" do
      source = source_fixture("repo-a")
      chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/exists.ex"})

      path =
        write_queries!([
          %{
            "query" => "no such file",
            "relevant" => [%{"path_prefix" => "lib/does_not_exist.ex"}]
          }
        ])

      assert {:ok, quality} = Runner.run(queries_path: path, skip_embed_probe: true).quality
      assert quality.queries_total == 1
      assert quality.queries_resolved == 0
      assert quality.queries_unresolved == 1
      assert quality.mean_ndcg_at_k == nil
    end

    test "quality is skipped when the corpus is empty" do
      path = write_queries!([%{"query" => "q", "relevant" => [%{"repo" => "r"}]}])

      assert {:skipped, reason} =
               Runner.run(queries_path: path, skip_embed_probe: true).quality

      assert reason =~ "corpus not seeded"
    end

    test "embed probe runs against StubImpl and reports throughput + RAM shape" do
      source = source_fixture("repo-a")
      chunk_fixture(source, repo: "repo-a", metadata: %{"path" => "lib/foo.ex"})

      path = write_queries!([%{"query" => "q", "relevant" => [%{"repo" => "repo-a"}]}])

      result = Runner.run(queries_path: path, skip_embed_probe: false)

      assert {:ok, probe} = result.embed_probe
      assert probe.passages == 20
      assert is_float(probe.throughput_passages_per_sec)
      assert probe.throughput_passages_per_sec > 0
      assert is_float(probe.ram.erlang_total_delta_mb)
    end
  end
end
