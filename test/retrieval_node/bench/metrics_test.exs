defmodule RetrievalNode.Bench.MetricsTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Bench.Metrics

  describe "ndcg_at_k/3" do
    test "hand-computed example: ranked [a,b,c,d], relevant {b,d}" do
      # gains by rank: a=0, b=1, c=0, d=1
      # DCG   = 0/log2(2) + 1/log2(3) + 0/log2(4) + 1/log2(5)
      #       = 1/log2(3) + 1/log2(5) ≈ 0.63093 + 0.43068 ≈ 1.06161
      # IDCG  = 1/log2(2) + 1/log2(3) (2 relevant docs ranked first)
      #       = 1 + 0.63093 ≈ 1.63093
      # nDCG  = 1.06161 / 1.63093 ≈ 0.65092
      ranked = ["a", "b", "c", "d"]
      relevant = MapSet.new(["b", "d"])

      assert_in_delta Metrics.ndcg_at_k(ranked, relevant, 10), 0.65092, 0.0001
    end

    test "perfect ranking (all relevant docs first) scores 1.0" do
      ranked = ["a", "b", "c", "d"]
      relevant = MapSet.new(["a", "b"])

      assert_in_delta Metrics.ndcg_at_k(ranked, relevant, 10), 1.0, 0.0001
    end

    test "no overlap between ranked and relevant scores 0.0" do
      ranked = ["a", "b", "c"]
      relevant = MapSet.new(["x", "y"])

      assert Metrics.ndcg_at_k(ranked, relevant, 10) == 0.0
    end

    test "empty relevant set scores 0.0 rather than raising" do
      assert Metrics.ndcg_at_k(["a", "b"], MapSet.new(), 10) == 0.0
    end

    test "only the leading k ranks count toward DCG" do
      # relevant doc "z" sits at rank 3; k=2 excludes it entirely.
      ranked = ["a", "b", "z"]
      relevant = MapSet.new(["z"])

      assert Metrics.ndcg_at_k(ranked, relevant, 2) == 0.0
    end

    test "relevant doc beyond the corpus (never retrieved) still normalizes correctly" do
      # 2 relevant docs exist, but only 1 was retrieved (at rank 1).
      ranked = ["a"]
      relevant = MapSet.new(["a", "unretrieved"])

      # DCG = 1/log2(2) = 1.0
      # IDCG = 1/log2(2) + 1/log2(3) ≈ 1.63093 (ideal ranks both relevant docs first)
      assert_in_delta Metrics.ndcg_at_k(ranked, relevant, 10), 1.0 / 1.63093, 0.0001
    end
  end

  describe "percentile/2" do
    test "nearest-rank method over 1..10" do
      values = Enum.to_list(1..10)

      assert Metrics.percentile(values, 50) == 5
      assert Metrics.percentile(values, 95) == 10
      assert Metrics.percentile(values, 99) == 10
      assert Metrics.percentile(values, 100) == 10
    end

    test "handles unsorted input" do
      assert Metrics.percentile([30, 10, 20], 50) == 20
    end

    test "single-element list returns that element at any percentile" do
      assert Metrics.percentile([42], 1) == 42
      assert Metrics.percentile([42], 99) == 42
    end

    test "empty list returns nil" do
      assert Metrics.percentile([], 50) == nil
    end
  end

  describe "percentiles/2" do
    test "computes multiple percentiles at once" do
      values = Enum.to_list(1..10)

      assert Metrics.percentiles(values, [50, 95, 99]) == %{50 => 5, 95 => 10, 99 => 10}
    end

    test "empty list maps every percentile to nil" do
      assert Metrics.percentiles([], [50, 99]) == %{50 => nil, 99 => nil}
    end
  end
end
