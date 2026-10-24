defmodule RetrievalNode.ChunkingTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Chunking

  describe "binary_content?/1" do
    test "false for plain text" do
      refute Chunking.binary_content?("def a():\n    return 1\n")
    end

    test "true for content containing a NUL byte" do
      assert Chunking.binary_content?(<<0, 255, 216, 0>>)
    end

    test "true for content that is invalid UTF-8 but has no NUL byte" do
      assert Chunking.binary_content?(<<255, 254>> <> "text")
    end

    test "false for empty content" do
      refute Chunking.binary_content?("")
    end
  end

  describe "chunk_with_graph/2 (heuristic impl — test env default, no NIF)" do
    test "the configured impl does not export chunk_with_graph/2" do
      refute function_exported?(Chunking.impl(), :chunk_with_graph, 2)
    end

    test "wraps chunk/2's result with empty entities/references" do
      source = "def foo\n  1\nend\n"
      {:ok, chunks} = Chunking.chunk(source, "ruby")

      assert {:ok, %{chunks: ^chunks, entities: [], references: []}} =
               Chunking.chunk_with_graph(source, "ruby")
    end
  end
end
