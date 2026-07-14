defmodule RetrievalNode.Search.HybridQueryTest do
  use RetrievalNode.DataCase, async: true

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
  end
end
