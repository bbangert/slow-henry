defmodule RetrievalNode.Chunking.TreeSitterImportRangesTest do
  # `import_ranges` on toplevel (gap) chunks: byte ranges, relative to the
  # chunk's start, of the import statements lying fully inside it. async: false
  # — shares the application-owned ChunkTaskSupervisor with the other
  # tree-sitter chunker tests.
  use ExUnit.Case, async: false

  @moduletag :tree_sitter

  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  defp chunks!(source, lang) do
    assert {:ok, chunks} = TSI.chunk(source, lang)
    chunks
  end

  defp toplevel(chunks), do: Enum.filter(chunks, &(&1.kind == "toplevel"))

  # The text of each import range of every toplevel chunk, sliced out of the
  # chunk text by its relative offsets.
  defp imported(chunks) do
    chunks
    |> toplevel()
    |> Enum.flat_map(fn c ->
      for {s, e} <- c.import_ranges, do: binary_part(c.text, s, e - s)
    end)
  end

  describe "per-language import statements" do
    test "python: import and from-import, not imports inside functions" do
      src = ~S'''
      import os
      from a.b import (c,
                       d)
      X = 1

      def f():
          import json
      '''

      assert imported(chunks!(src, "python")) == [
               "import os",
               "from a.b import (c,\n                 d)"
             ]
    end

    test "javascript and typescript: import statements, not re-exports" do
      src = ~S'''
      import a from "a";
      import {b} from "b";
      export {c} from "c";
      const X = 1;
      '''

      for lang <- ~w(javascript typescript) do
        assert imported(chunks!(src, lang)) == [~S'import a from "a";', ~S'import {b} from "b";']
      end
    end

    test "go: single and grouped import declarations" do
      src = ~S'''
      package main

      import "fmt"

      import (
      	"os"
      	str "strings"
      )

      var X = 1

      func main() {}
      '''

      assert imported(chunks!(src, "go")) == [
               ~S'import "fmt"',
               "import (\n\t\"os\"\n\tstr \"strings\"\n)"
             ]
    end

    test "rust: use declarations" do
      src = ~S'''
      use std::io;
      use a::{b, c};
      const X: u32 = 1;

      fn f() {}
      '''

      assert imported(chunks!(src, "rust")) == ["use std::io;", "use a::{b, c};"]
    end

    test "java: import declarations" do
      src = ~S'''
      package p;

      import java.util.List;
      import static a.B.c;

      public class A {
        int x = 1;
        void f() {}
      }
      '''

      assert imported(chunks!(src, "java")) == ["import java.util.List;", "import static a.B.c;"]
    end

    test "ruby: require / require_relative of string literals only" do
      src = ~S'''
      require "json"
      require_relative "./helper"
      require name
      Kernel.require "set"
      other.require "x"
      LIMIT = 1

      def f; end
      '''

      assert imported(chunks!(src, "ruby")) ==
               [~S'require "json"', ~S'require_relative "./helper"', ~S'Kernel.require "set"']
    end

    test "elixir: alias / import / use / require, in nested module bodies too" do
      src = ~S'''
      defmodule A do
        use Foo, opts: 1
        alias A.B
        import C, only: [d: 1]
        require Logger
        @x 1
        IO.puts("hi")

        def f, do: 1
      end
      '''

      assert imported(chunks!(src, "elixir")) ==
               ["use Foo, opts: 1", "alias A.B", "import C, only: [d: 1]", "require Logger"]
    end
  end

  describe "ranges" do
    test "are relative to the chunk and slice exactly the import text" do
      src = "import os\nimport sys\n\nX = 1\n"
      [chunk] = src |> chunks!("python") |> toplevel()

      assert chunk.import_ranges == [{0, 9}, {10, 20}]
      assert chunk.start_byte == 0

      # A chunk that does not start at byte 0 still gets relative offsets.
      src2 = "\n\n# lead\nimport os\nX = 1\n\ndef f():\n    pass\n"
      [chunk2 | _] = src2 |> chunks!("python") |> toplevel()
      assert chunk2.start_byte > 0
      [{s, e}] = chunk2.import_ranges
      assert binary_part(chunk2.text, s, e - s) == "import os"
    end

    test "definition chunks carry none" do
      chunks = chunks!("import os\n\ndef f():\n    return 1\n", "python")
      defs = Enum.reject(chunks, &(&1.kind == "toplevel"))

      assert defs != []
      refute Enum.any?(defs, &Map.has_key?(&1, :import_ranges))
    end

    test "a toplevel chunk with no imports has an empty list" do
      [chunk] = "X = 1\n" |> chunks!("python") |> toplevel()
      assert chunk.import_ranges == []
    end

    test "split pieces get only their own imports" do
      filler = for i <- 1..400, into: "", do: "V#{i} = #{i}\n"
      src = "import first\n\n" <> filler <> "\nimport second\n\nTAIL = 1\n"

      pieces = src |> chunks!("python") |> toplevel()
      assert length(pieces) > 1

      assert Enum.map(pieces, &Enum.count(&1.import_ranges)) |> Enum.sum() == 2

      for piece <- pieces, {s, e} <- piece.import_ranges do
        assert binary_part(piece.text, s, e - s) in ["import first", "import second"]
      end

      assert hd(pieces).import_ranges |> length() == 1
      assert List.last(pieces).import_ranges |> length() == 1
    end
  end
end
