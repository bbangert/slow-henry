defmodule RetrievalNode.Embedding.NxServingImplTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Embedding.NxServingImpl

  describe "dimensions/0" do
    test "reports the Matryoshka-truncated dimensionality" do
      assert NxServingImpl.dimensions() == 384
    end
  end

  describe "matryoshka/1 (pure truncation math)" do
    test "truncates a 768-dim embedding to 384 dims" do
      tensor = Nx.tensor(for i <- 1..768, do: i * 0.001)
      result = NxServingImpl.matryoshka(tensor)
      assert length(result) == 384
    end

    test "L2-normalizes the truncated vector to unit length" do
      # A non-normalized 768-vector; after truncation + renormalization the
      # result must have unit L2 norm regardless of the input magnitude.
      tensor = Nx.tensor(for i <- 1..768, do: i * 1.0)
      result = NxServingImpl.matryoshka(tensor)

      norm = result |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      assert_in_delta norm, 1.0, 1.0e-5
    end

    test "keeps the LEADING 384 dims (not the trailing), then renormalizes" do
      # Distinct leading vs trailing halves: leading = 1s, trailing = 9s. The
      # result must derive from the 1s half (all equal ⇒ each entry 1/sqrt(384)).
      values = List.duplicate(1.0, 384) ++ List.duplicate(9.0, 384)
      result = NxServingImpl.matryoshka(Nx.tensor(values))

      expected = 1.0 / :math.sqrt(384)
      assert Enum.all?(result, &(abs(&1 - expected) < 1.0e-6))
    end

    test "accepts the serving's %{embedding: tensor} result shape" do
      tensor = Nx.tensor(for i <- 1..768, do: i * 0.01)
      assert NxServingImpl.matryoshka(%{embedding: tensor}) == NxServingImpl.matryoshka(tensor)
    end

    test "an all-zero vector yields a finite (zero) result, not NaN" do
      # Guards the epsilon floor in l2_normalize: dividing by a zero norm would
      # otherwise produce NaN, which would silently poison pgvector.
      result = NxServingImpl.matryoshka(Nx.broadcast(0.0, {768}))

      assert length(result) == 384
      # All entries equal 0.0 — which also proves none are NaN (NaN == 0.0 is false),
      # so the epsilon floor prevented the divide-by-zero NaN.
      assert Enum.all?(result, &(&1 == 0.0))
    end
  end

  # Loads the real model + EXLA and embeds through the serving. Excluded by
  # default (see test_helper.exs); run with `mix test --include integration`.
  describe "embed/1 through the loaded model" do
    @describetag :integration

    setup do
      start_supervised!(RetrievalNode.Embedding.Serving)
      :ok
    end

    test "embeds text into a 384-dim unit vector" do
      vector = NxServingImpl.embed("the quick brown fox")

      assert length(vector) == 384
      norm = vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      assert_in_delta norm, 1.0, 1.0e-4
    end

    test "embed_batch/1 returns one vector per input, in order" do
      vectors = NxServingImpl.embed_batch(["alpha", "beta", "gamma"])

      assert length(vectors) == 3
      assert Enum.all?(vectors, &(length(&1) == 384))
    end
  end
end
