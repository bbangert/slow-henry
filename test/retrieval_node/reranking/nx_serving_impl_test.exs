defmodule RetrievalNode.Reranking.NxServingImplTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Reranking.NxServingImpl

  describe "truncate_passage/1 (pure byte-cap truncation)" do
    test "leaves a short passage unchanged" do
      assert NxServingImpl.truncate_passage("a short passage") == "a short passage"
    end

    test "leaves the empty string unchanged" do
      assert NxServingImpl.truncate_passage("") == ""
    end

    test "leaves a passage exactly at the byte cap unchanged" do
      passage = String.duplicate("a", 2_000)
      assert NxServingImpl.truncate_passage(passage) == passage
    end

    test "truncates an oversized passage to at most 2000 bytes" do
      passage = String.duplicate("a", 3_000)
      result = NxServingImpl.truncate_passage(passage)

      assert byte_size(result) <= 2_000
      assert result == String.duplicate("a", 2_000)
    end

    test "truncates cleanly even when the byte cap lands mid-codepoint" do
      # 1_999 ASCII bytes + "éé" (each é is 2 UTF-8 bytes) = 2_003 bytes total.
      # A raw byte cut at 2_000 lands right after the first byte of the first
      # é, splitting its 2-byte encoding — the result must still be valid
      # UTF-8 and must not exceed the byte cap.
      passage = String.duplicate("a", 1_999) <> "éé"
      assert byte_size(passage) == 2_003
      refute String.valid?(binary_part(passage, 0, 2_000))

      result = NxServingImpl.truncate_passage(passage)

      assert String.valid?(result)
      assert byte_size(result) <= 2_000
      assert result == String.duplicate("a", 1_999)
    end
  end

  describe "truncate_query/1 (pure byte-cap truncation)" do
    test "leaves a short query unchanged" do
      assert NxServingImpl.truncate_query("what does process_payment do?") ==
               "what does process_payment do?"
    end

    test "truncates a multi-KB query to at most 512 bytes" do
      query = String.duplicate("a", 2_000)
      result = NxServingImpl.truncate_query(query)

      assert byte_size(result) <= 512
      assert result == String.duplicate("a", 512)
    end

    test "truncates cleanly even when the byte cap lands mid-codepoint" do
      query = String.duplicate("a", 511) <> "éé"
      refute String.valid?(binary_part(query, 0, 512))

      result = NxServingImpl.truncate_query(query)

      assert String.valid?(result)
      assert byte_size(result) <= 512
    end
  end

  describe "rerank_scores/2's pairing bounds the query once for the whole pool" do
    # rerank_scores/2 itself calls the real Nx.Serving (RetrievalNode.Reranking.Serving),
    # which this unit test's supervision tree doesn't start — so this checks
    # the pure pieces rerank_scores/2 composes its pairs from (truncate_query/1
    # + truncate_passage/1) directly, at the same {query, passage} pairing
    # shape rerank_scores/2 builds, rather than standing up the serving.
    test "a multi-KB query still yields exactly one bounded pair per passage" do
      big_query = String.duplicate("q", 5_000)
      passages = ["short passage", String.duplicate("p", 3_000)]

      truncated_query = NxServingImpl.truncate_query(big_query)
      pairs = Enum.map(passages, &{truncated_query, NxServingImpl.truncate_passage(&1)})

      assert length(pairs) == length(passages)

      Enum.each(pairs, fn {q, p} ->
        assert byte_size(q) <= 512
        assert byte_size(p) <= 2_000
      end)
    end
  end
end
