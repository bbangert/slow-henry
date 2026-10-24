defmodule RetrievalNode.Reranking.NxServingImplTest do
  # async: false — the serving tests register the global Serving.name().
  use ExUnit.Case, async: false

  alias RetrievalNode.Reranking.{NxServingImpl, Serving}

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

  describe "rerank_scores/2 through a model-free serving" do
    # A fake Nx.Serving registered under Serving.name() records the pairs the
    # adapter submits and scores each by its passage's byte size, so the test
    # sees the real adapter's truncation, pairing and score extraction.
    setup do
      test = self()

      serving =
        Nx.Serving.new(fn opts -> Nx.Defn.jit(&Function.identity/1, opts) end)
        |> Nx.Serving.client_preprocessing(fn pairs ->
          send(test, {:pairs, pairs})
          {Nx.Batch.stack(Enum.map(pairs, fn _ -> Nx.tensor(0) end)), pairs}
        end)
        |> Nx.Serving.client_postprocessing(fn _output, pairs ->
          Enum.map(pairs, fn {_q, p} -> %{score: byte_size(p) * 1.0} end)
        end)

      start_supervised!({Nx.Serving, serving: serving, name: Serving.name()})
      :ok
    end

    test "submits one bounded pair per passage and returns scores in passage order" do
      passages = [String.duplicate("p", 3_000), "short passage"]

      assert NxServingImpl.rerank_scores(String.duplicate("q", 5_000), passages) ==
               [2_000.0, 13.0]

      assert_receive {:pairs, [{q, p1}, {q, "short passage"}]}
      assert byte_size(q) == 512 and byte_size(p1) == 2_000
    end
  end

  # Loads the real cross-encoder; run with `mix test --include integration`.
  describe "rerank_scores/2 through the loaded model" do
    @describetag :integration

    setup do
      start_supervised!(Serving)
      :ok
    end

    test "returns one float logit per passage, ranking the relevant passage first" do
      [relevant, other] =
        NxServingImpl.rerank_scores("how do I reset a password?", [
          "To reset your password, open settings and choose reset password.",
          "The weather in Lisbon is mild in spring."
        ])

      assert is_float(relevant) and is_float(other)
      assert relevant > other
    end
  end
end
