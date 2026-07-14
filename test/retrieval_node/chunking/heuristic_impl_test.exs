defmodule RetrievalNode.Chunking.HeuristicImplTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Chunking.HeuristicImpl

  test "splits on blank-line boundaries into separate chunks" do
    source = "line a1\nline a2\n\nline b1\nline b2\n"
    {:ok, chunks} = HeuristicImpl.chunk(source, "text")

    assert length(chunks) == 2
    assert Enum.at(chunks, 0).text == "line a1\nline a2"
    assert Enum.at(chunks, 1).text == "line b1\nline b2"
  end

  test "records accurate 1-based start/end line numbers" do
    source = "a\n\nb\nc\n"
    {:ok, [first, second]} = HeuristicImpl.chunk(source, "text")

    assert {first.start_line, first.end_line} == {1, 1}
    assert {second.start_line, second.end_line} == {3, 4}
  end

  test "does not split inside an unbalanced brace block" do
    # The blank line sits inside the {...} block, so the block stays one chunk.
    source = "func() {\n  a();\n\n  b();\n}\n\nother()\n"
    {:ok, chunks} = HeuristicImpl.chunk(source, "js")

    assert hd(chunks).text == "func() {\n  a();\n\n  b();\n}"
    assert length(chunks) == 2
  end

  test "tags chunks as heuristic_fallback with an empty breadcrumb" do
    {:ok, [chunk]} = HeuristicImpl.chunk("only one block\n", "text")

    assert chunk.parse_status == :heuristic_fallback
    assert chunk.breadcrumb == ""
    assert chunk.kind == "heuristic_block"
  end

  test "always produces at least one chunk for non-empty content (fallback guarantee)" do
    {:ok, chunks} = HeuristicImpl.chunk("x = 1\n", "text")
    assert length(chunks) == 1
  end

  test "returns no chunks for whitespace-only input" do
    assert {:ok, []} = HeuristicImpl.chunk("\n\n   \n", "text")
  end
end
