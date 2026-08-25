defmodule RetrievalNode.Search.HybridQueryTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Graph.{Entity, EntityMention}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}
  alias RetrievalNode.Search
  alias RetrievalNode.Search.HybridQuery

  @dim 384

  # A 384-dim unit vector with 1.0 at `i`, zeros elsewhere. Distinct axes give
  # deterministic cosine distances: `<=>` between two different axes is 1.0,
  # between the same axis 0.0.
  defp axis(i) do
    for j <- 0..(@dim - 1), do: if(j == i, do: 1.0, else: 0.0)
  end

  # A unit vector in the (axis 0, axis 1) plane at angle `theta`. Cosine distance
  # to the query `axis(0)` grows monotonically with theta, so a set of graded
  # vectors gives a strict cosine ranking (unlike distinct axes, which all tie at
  # distance 1.0). Used to build ranked decoys for the pool-starvation test.
  defp graded(theta) do
    for j <- 0..(@dim - 1) do
      cond do
        j == 0 -> :math.cos(theta)
        j == 1 -> :math.sin(theta)
        true -> 0.0
      end
    end
  end

  defp source_fixture(identifier) do
    Repo.insert!(%Source{
      source_type: :git_repo,
      name: identifier,
      identifier: identifier
    })
  end

  defp chunk_fixture(source, attrs) do
    defaults = %{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "hash-#{System.unique_integer([:positive])}",
      context_breadcrumb: "lib/foo.ex > Foo",
      metadata: %{}
    }

    attrs =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Map.update!(:embedding, &Pgvector.new/1)

    Repo.insert!(struct(Chunk, attrs))
  end

  # A chunk with no embedding and content chosen not to match the FTS query
  # under test — reachable, if at all, only via the entity leg. `embedding`
  # is nullable at the DB level (chunks awaiting embedding), so this is a
  # legitimate real state, not a test-only hack.
  defp graph_only_chunk_fixture(source, attrs) do
    defaults = %{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "hash-#{System.unique_integer([:positive])}",
      context_breadcrumb: "lib/foo.ex > Foo",
      metadata: %{},
      embedding: nil
    }

    Repo.insert!(struct(Chunk, Map.merge(defaults, Map.new(attrs))))
  end

  defp entity_fixture(source, attrs) do
    defaults = %{
      source_id: source.id,
      language: "python",
      kind: :function
    }

    Repo.insert!(struct(Entity, Map.merge(defaults, Map.new(attrs))))
  end

  defp mention_fixture(entity, chunk, kind) do
    Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: kind})
  end

  describe "search/1 RRF ordering" do
    test "ranks the chunk matching on both vector and text above a non-match" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source,
          repo: "repo-a",
          content: "the quick brown fox jumps over the lazy dog",
          embedding: axis(0)
        )

      _miss =
        chunk_fixture(source,
          repo: "repo-a",
          content: "entirely unrelated lorem ipsum dolor sit amet",
          embedding: axis(1)
        )

      results =
        HybridQuery.search(
          embedding: axis(0),
          text_query: "quick brown fox"
        )

      assert [%{chunk_id: top_id} | _] = results
      assert top_id == match.id
    end
  end

  describe "search/1 filter isolation" do
    test "a repo filter cannot surface the globally-best chunk from another repo" do
      source = source_fixture("repo-a")

      # The globally-best match on BOTH signals lives in repo-b: identical
      # embedding to the query and a strong text match. If filters were applied
      # only after fusion, it would consume a rank-1 slot and leak through.
      best_out_of_scope =
        chunk_fixture(source,
          repo: "repo-b",
          content: "the quick brown fox jumps",
          embedding: axis(0)
        )

      in_scope =
        chunk_fixture(source,
          repo: "repo-a",
          content: "a quick brown fox appears here too",
          embedding: axis(0)
        )

      results =
        HybridQuery.search(
          embedding: axis(0),
          text_query: "quick brown fox",
          repo: "repo-a"
        )

      returned_ids = Enum.map(results, & &1.chunk_id)

      refute best_out_of_scope.id in returned_ids
      assert in_scope.id in returned_ids
      assert Enum.all?(results, &(&1.repo == "repo-a"))
    end

    test "in-scope chunk survives even when out-of-scope decoys would starve the candidate pool" do
      # This is the discriminating test: with :rrf_candidate_pool = 5 (test config)
      # we seed 6 out-of-scope (repo-b) decoys that ALL rank above the single
      # in-scope (repo-a) chunk on cosine, and that ALSO match the FTS text. The
      # in-scope chunk is far on cosine AND has no text match, so it only qualifies
      # by living in the *filtered* vector CTE. If the source/repo filter were
      # applied after fusion instead of inside both CTEs, the 6 decoys would fill
      # the pool-of-5 on both sides, the in-scope chunk would never enter the
      # candidate set, and the post-fusion filter could not resurrect it — the
      # result would be empty and this assertion would fail. Filters-inside-CTE is
      # exactly what keeps the in-scope chunk present.
      source = source_fixture("repo-a")

      for i <- 1..6 do
        chunk_fixture(source,
          repo: "repo-b",
          content: "the quick brown fox jumps repeatedly",
          embedding: graded(0.01 * i)
        )
      end

      in_scope =
        chunk_fixture(source,
          repo: "repo-a",
          content: "zebra giraffe elephant antelope",
          embedding: graded(1.5)
        )

      results =
        HybridQuery.search(
          embedding: graded(0.0),
          text_query: "quick brown fox",
          repo: "repo-a"
        )

      returned_ids = Enum.map(results, & &1.chunk_id)

      assert in_scope.id in returned_ids
      assert Enum.all?(results, &(&1.repo == "repo-a"))
    end
  end

  describe "Search.hybrid_search/2 public API" do
    test "assembles back-link hits with score and no content field" do
      source = source_fixture("repo-a")

      chunk =
        chunk_fixture(source,
          repo: "repo-a",
          lang: "elixir",
          content: "the quick brown fox",
          context_breadcrumb: "lib/foo.ex > Foo > bar/1",
          metadata: %{"path" => "lib/foo.ex"},
          embedding: axis(0)
        )

      [hit | _] =
        Search.hybrid_search("quick brown fox", embedding: axis(0), repo: "repo-a")

      assert %{chunk: chunk_map, score: score} = hit
      assert is_float(score)
      assert chunk_map.id == chunk.id
      assert chunk_map.context_breadcrumb == "lib/foo.ex > Foo > bar/1"
      assert chunk_map.metadata == %{"path" => "lib/foo.ex"}
      # back-link projection must NOT leak full content
      refute Map.has_key?(chunk_map, :content)
    end

    test "rerank: false (default) hits have no fused_score key" do
      source = source_fixture("repo-a")

      chunk_fixture(source,
        repo: "repo-a",
        content: "the quick brown fox",
        embedding: axis(0)
      )

      [hit | _] = Search.hybrid_search("quick brown fox", embedding: axis(0), repo: "repo-a")

      refute Map.has_key?(hit, :fused_score)
    end
  end

  describe "Search.hybrid_search/2 rerank" do
    alias RetrievalNode.Reranking.StubImpl

    test "rerank: true orders hits by stub rerank score and carries fused_score" do
      source = source_fixture("repo-a")
      query = "quick brown fox"

      chunks =
        for i <- 1..4 do
          chunk_fixture(source,
            repo: "repo-a",
            content: "quick brown fox variant #{i}",
            embedding: axis(0)
          )
        end

      hits =
        Search.hybrid_search(query,
          embedding: axis(0),
          repo: "repo-a",
          rerank: true,
          top_k: 4
        )

      expected_order =
        chunks
        |> Enum.map(& &1.content)
        |> then(&StubImpl.rerank_scores(query, &1))
        |> Enum.zip(chunks)
        |> Enum.sort_by(fn {score, _chunk} -> score end, :desc)
        |> Enum.map(fn {_score, chunk} -> chunk.id end)

      assert Enum.map(hits, & &1.chunk.id) == expected_order
      assert length(hits) <= 4

      Enum.each(hits, fn hit ->
        assert %{chunk: _chunk, score: score, fused_score: fused_score} = hit
        assert is_float(score)
        assert is_float(fused_score)
      end)
    end

    test "rerank funnel: top_k caps to the highest rerank-scored candidates regardless of fused rank" do
      source = source_fixture("repo-a")
      query = "quick brown fox"

      chunks =
        for i <- 1..5 do
          chunk_fixture(source,
            repo: "repo-a",
            content: "quick brown fox funnel #{i}",
            embedding: axis(0)
          )
        end

      expected_top2 =
        chunks
        |> Enum.map(& &1.content)
        |> then(&StubImpl.rerank_scores(query, &1))
        |> Enum.zip(chunks)
        |> Enum.sort_by(fn {score, _chunk} -> score end, :desc)
        |> Enum.take(2)
        |> Enum.map(fn {_score, chunk} -> chunk.id end)

      hits =
        Search.hybrid_search(query,
          embedding: axis(0),
          repo: "repo-a",
          rerank: true,
          top_k: 2
        )

      assert Enum.map(hits, & &1.chunk.id) == expected_top2
    end

    test "rerank normalizes an invalid top_k the same way the non-rerank path does (no raise, default 20)" do
      source = source_fixture("repo-a")
      query = "quick brown fox"

      chunks =
        for i <- 1..3 do
          chunk_fixture(source,
            repo: "repo-a",
            content: "quick brown fox variant #{i}",
            embedding: axis(0)
          )
        end

      for bad_top_k <- [-1, "nope"] do
        rerank_hits =
          Search.hybrid_search(query,
            embedding: axis(0),
            repo: "repo-a",
            rerank: true,
            top_k: bad_top_k
          )

        non_rerank_hits =
          Search.hybrid_search(query,
            embedding: axis(0),
            repo: "repo-a",
            rerank: false,
            top_k: bad_top_k
          )

        # top_k clamps to the default (20), which is >= all 3 seeded chunks —
        # both paths return every chunk instead of raising or silently
        # dropping results (the pre-fix Enum.take(-1) bug, or a raise on a
        # non-integer top_k reaching Enum.take/2 or Postgres' $4 bind).
        assert length(rerank_hits) == length(chunks)
        assert length(non_rerank_hits) == length(chunks)
      end
    end
  end

  describe "significant_terms/1" do
    test "keeps snake_case symbols intact as one term" do
      assert HybridQuery.significant_terms("check process_payment flow") ==
               ["check", "process_payment", "flow"]
    end

    test "drops terms shorter than 3 chars" do
      assert HybridQuery.significant_terms("a to is payment") == ["payment"]
    end

    test "dedups preserving first-seen order" do
      assert HybridQuery.significant_terms("payment payment refund payment") ==
               ["payment", "refund"]
    end

    test "caps at 8 terms" do
      text = Enum.map_join(1..12, " ", &"term#{&1}")

      assert HybridQuery.significant_terms(text) ==
               Enum.map(1..8, &"term#{&1}")
    end

    test "empty (or all-short-word) query yields no terms" do
      assert HybridQuery.significant_terms("") == []
      assert HybridQuery.significant_terms("to a is") == []
    end

    test "drops terms longer than 64 chars" do
      giant = String.duplicate("a", 65)

      assert HybridQuery.significant_terms("short #{giant} term") == ["short", "term"]
    end

    test ~s(drops stopwords like "the" and "how" while keeping real terms) do
      assert HybridQuery.significant_terms("how does the process work") == ["process", "work"]
    end

    test "does not drop code-symbol words that double as stopword-length terms (get/all/run)" do
      assert HybridQuery.significant_terms("get all run") == ["get", "all", "run"]
    end

    test "an all-stopwords query (not just all-short-word) yields no terms" do
      assert HybridQuery.significant_terms("how does this and that would") == []
    end
  end

  describe "search/1 graph leg toggle" do
    test "graph: false (and default-off) leave two-leg ranking unchanged" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source,
          repo: "repo-a",
          content: "the quick brown fox jumps",
          embedding: axis(0)
        )

      _miss =
        chunk_fixture(source,
          repo: "repo-a",
          content: "entirely unrelated lorem ipsum",
          embedding: axis(1)
        )

      # An entity/mention that COULD contribute via the graph leg if it ran —
      # its presence must not change anything while the leg is off.
      entity = entity_fixture(source, qualified_name: "PaymentProcessor.process_payment")

      graph_only =
        graph_only_chunk_fixture(source,
          repo: "repo-a",
          content: "totally unrelated filler about zebras"
        )

      mention_fixture(entity, graph_only, :definition)

      query_text = "quick brown fox payment"

      default_results = HybridQuery.search(embedding: axis(0), text_query: query_text)

      explicit_off_results =
        HybridQuery.search(embedding: axis(0), text_query: query_text, graph: false)

      assert Enum.map(default_results, & &1.chunk_id) ==
               Enum.map(explicit_off_results, & &1.chunk_id)

      returned_ids = Enum.map(default_results, & &1.chunk_id)
      assert hd(default_results).chunk_id == match.id
      refute graph_only.id in returned_ids
    end

    test "graph: true surfaces a chunk reachable only via an entity mention" do
      source = source_fixture("repo-a")
      entity = entity_fixture(source, qualified_name: "PaymentProcessor.process_payment")

      graph_only =
        graph_only_chunk_fixture(source,
          repo: "repo-a",
          content: "totally unrelated filler about zebras"
        )

      mention_fixture(entity, graph_only, :definition)

      # Decoy: no entity mention, and matches neither the vector nor FTS query.
      _decoy =
        graph_only_chunk_fixture(source,
          repo: "repo-a",
          content: "more unrelated filler about giraffes"
        )

      results_off =
        HybridQuery.search(embedding: axis(0), text_query: "payment processing", graph: false)

      results_on =
        HybridQuery.search(embedding: axis(0), text_query: "payment processing", graph: true)

      refute graph_only.id in Enum.map(results_off, & &1.chunk_id)
      assert graph_only.id in Enum.map(results_on, & &1.chunk_id)
    end

    test "definition mentions outrank import mentions for the same entity match" do
      source = source_fixture("repo-a")
      entity = entity_fixture(source, qualified_name: "PaymentProcessor.process_payment")

      # Content/embedding on both chunks are chosen so neither the vector nor
      # FTS leg contributes anything — the only signal is the entity mention.
      def_chunk =
        graph_only_chunk_fixture(source,
          repo: "repo-a",
          content: "unrelated filler alpha"
        )

      import_chunk =
        graph_only_chunk_fixture(source,
          repo: "repo-a",
          content: "unrelated filler beta"
        )

      mention_fixture(entity, def_chunk, :definition)
      mention_fixture(entity, import_chunk, :import)

      results = HybridQuery.search(embedding: axis(0), text_query: "payment", graph: true)

      ids = Enum.map(results, & &1.chunk_id)
      def_rank = Enum.find_index(ids, &(&1 == def_chunk.id))
      import_rank = Enum.find_index(ids, &(&1 == import_chunk.id))

      assert is_integer(def_rank)
      assert is_integer(import_rank)
      assert def_rank < import_rank
    end

    test "graph: true with an all-stopwords query falls back to the two-leg query (no crash, results still returned)" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source,
          repo: "repo-a",
          content: "the quick brown fox jumps",
          embedding: axis(0)
        )

      results =
        HybridQuery.search(
          embedding: axis(0),
          text_query: "how does this and that would",
          graph: true
        )

      assert Enum.map(results, & &1.chunk_id) == [match.id]
    end

    test "three-way mention-kind ordering: definition > call > import for the same entity match" do
      source = source_fixture("repo-a")
      entity = entity_fixture(source, qualified_name: "PaymentProcessor.process_payment")

      # Content/embedding on all three chunks are chosen so neither the
      # vector nor FTS leg contributes anything — the only signal is each
      # chunk's entity mention kind.
      def_chunk =
        graph_only_chunk_fixture(source, repo: "repo-a", content: "unrelated filler alpha")

      call_chunk =
        graph_only_chunk_fixture(source, repo: "repo-a", content: "unrelated filler gamma")

      import_chunk =
        graph_only_chunk_fixture(source, repo: "repo-a", content: "unrelated filler beta")

      mention_fixture(entity, def_chunk, :definition)
      mention_fixture(entity, call_chunk, :call)
      mention_fixture(entity, import_chunk, :import)

      results = HybridQuery.search(embedding: axis(0), text_query: "payment", graph: true)

      ids = Enum.map(results, & &1.chunk_id)
      def_rank = Enum.find_index(ids, &(&1 == def_chunk.id))
      call_rank = Enum.find_index(ids, &(&1 == call_chunk.id))
      import_rank = Enum.find_index(ids, &(&1 == import_chunk.id))

      assert is_integer(def_rank)
      assert is_integer(call_rank)
      assert is_integer(import_rank)
      assert def_rank < call_rank
      assert call_rank < import_rank
    end

    test "entity leg respects the repo filter" do
      source = source_fixture("repo-a")
      entity = entity_fixture(source, qualified_name: "PaymentProcessor.process_payment")

      wrong_repo_chunk =
        graph_only_chunk_fixture(source, repo: "repo-b", content: "unrelated filler alpha")

      right_repo_chunk =
        graph_only_chunk_fixture(source, repo: "repo-a", content: "unrelated filler beta")

      mention_fixture(entity, wrong_repo_chunk, :definition)
      mention_fixture(entity, right_repo_chunk, :definition)

      results =
        HybridQuery.search(
          embedding: axis(0),
          text_query: "payment",
          graph: true,
          repo: "repo-a"
        )

      ids = Enum.map(results, & &1.chunk_id)

      refute wrong_repo_chunk.id in ids
      assert right_repo_chunk.id in ids
    end

    test "graph: true with no significant terms runs the two-leg query without crashing" do
      source = source_fixture("repo-a")

      match =
        chunk_fixture(source,
          repo: "repo-a",
          content: "the quick brown fox jumps",
          embedding: axis(0)
        )

      results = HybridQuery.search(embedding: axis(0), text_query: "to a is", graph: true)

      assert Enum.map(results, & &1.chunk_id) == [match.id]
    end
  end
end
