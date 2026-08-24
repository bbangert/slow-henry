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
end
