defmodule RetrievalNode.Chunking.EmbedTextTest do
  # async: false — the chunker-backed cases share the application-owned
  # ChunkTaskSupervisor with the other tree-sitter chunker tests.
  use ExUnit.Case, async: false

  alias RetrievalNode.Chunking.{Breadcrumb, EmbedText}
  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  defp build(attrs) do
    EmbedText.build(
      Map.merge(
        %{kind: "toplevel", breadcrumb: "lib/a.py", text: "X = 1", names: [], import_ranges: []},
        attrs
      )
    )
  end

  describe "pure rules" do
    test "toplevel with names: header line, blank line, text" do
      assert "lib/a.py — defines: X, Y\n\nX = 1\nY = 2" ==
               build(%{names: ["X", "Y"], text: "X = 1\nY = 2"})
    end

    test "toplevel with no names and no imports is byte-identical to legacy" do
      assert embed = build(%{})
      assert embed == Breadcrumb.prepend("lib/a.py", "X = 1")

      assert "X = 1" ==
               build(%{breadcrumb: nil})
    end

    test "import ranges are cut out and the blank-line runs collapsed" do
      text = "import os\nimport sys\n\n\nX = 1"

      assert "lib/a.py — defines: X\n\nX = 1" ==
               build(%{names: ["X"], text: text, import_ranges: [{0, 9}, {10, 20}]})
    end

    test "a chunk of only imports falls back to its text" do
      assert "lib/a.py\n\nimport os" ==
               build(%{text: "import os", import_ranges: [{0, 9}]})

      assert "lib/a.py — defines: os\n\nimport os" ==
               build(%{text: "import os", names: ["os"], import_ranges: [{0, 9}]})
    end

    test "stripping imports alone (no names) still drops them" do
      assert "lib/a.py\n\nX = 1" ==
               build(%{text: "import os\nX = 1", import_ranges: [{0, 9}]})
    end

    test "text with no imports is embedded as written" do
      assert "lib/a.py\n\na = 1\n\n\n\nb = 2" ==
               build(%{text: "a = 1\n\n\n\nb = 2"})
    end

    test "nil / empty breadcrumb: no header line" do
      assert "X = 1" ==
               build(%{breadcrumb: nil, names: ["X"]})

      assert "X = 1" ==
               build(%{breadcrumb: "", names: ["X"]})
    end

    test "definition chunks are byte-identical to the pre-format embed input" do
      for kind <- ["function_definition", "heuristic_block", nil] do
        chunk = %{kind: kind, breadcrumb: "lib/a.py > f", text: "def f():\n    pass"}
        embed = EmbedText.build(chunk)
        assert embed == "lib/a.py > f" <> "\n\n" <> "def f():\n    pass"
        assert embed == Breadcrumb.prepend(chunk.breadcrumb, chunk.text)
      end

      assert "bare" ==
               EmbedText.build(%{kind: "function_definition", breadcrumb: nil, text: "bare"})

      assert "bare" ==
               EmbedText.build(%{kind: "function_definition", breadcrumb: "", text: "bare"})
    end

    test "a definition chunk's names / import_ranges are ignored" do
      chunk = %{
        kind: "class",
        breadcrumb: "p",
        text: "import x",
        names: ["A"],
        import_ranges: [{0, 8}]
      }

      assert "p\n\nimport x" ==
               EmbedText.build(chunk)
    end
  end

  test "a remainder with no letter or digit falls back to the text; any identifier keeps it" do
    # "import os; import sys" with the two import nodes stripped leaves "; ".
    text = "import os; import sys"
    ranges = [{0, 9}, {11, 21}]
    assert "lib/a.py\n\n" <> text == build(%{text: text, import_ranges: ranges})

    # Only separators left -> falls back; any identifier left -> kept.
    only_sep = "a;  ,\nb"
    assert "lib/a.py\n\n" <> only_sep == build(%{text: only_sep, import_ranges: [{0, 1}, {6, 7}]})
    assert "lib/a.py\n\n;  ,\nx" == build(%{text: "a;  ,\nx", import_ranges: [{0, 1}]})
    assert "lib/a.py\n\nü" == build(%{text: "aü", import_ranges: [{0, 1}]})
  end

  test "legacy_text/2 is Breadcrumb.prepend/2, or bare text without a breadcrumb" do
    assert EmbedText.legacy_text("p > f", "t") == Breadcrumb.prepend("p > f", "t")
    assert EmbedText.legacy_text("", "t") == "t"
    assert EmbedText.legacy_text(nil, "t") == "t"
  end

  describe "on real chunker output" do
    @describetag :tree_sitter

    defp embed_toplevel(source, lang, path) do
      assert {:ok, chunks} = TSI.chunk(source, lang)

      for %{kind: "toplevel"} = c <- chunks do
        embed =
          EmbedText.build(%{
            kind: c.kind,
            breadcrumb: Breadcrumb.build(path, c.breadcrumb),
            text: c.text,
            names: c.names,
            import_ranges: c.import_ranges
          })

        embed
      end
    end

    test "python" do
      src =
        "import os\nfrom a import (b,\n  c)\n\nLIMIT = 3\nNAME: str = 'x'\n\ndef f():\n    pass\n"

      assert embed_toplevel(src, "python", "pkg/m.py") ==
               ["pkg/m.py — defines: LIMIT, NAME\n\nLIMIT = 3\nNAME: str = 'x'"]
    end

    test "javascript and typescript" do
      src = ~S'''
      import a from "a";
      export const ONE = 1, TWO = 2;
      function f() {}
      '''

      for lang <- ~w(javascript typescript) do
        assert embed_toplevel(src, lang, "src/x.js") ==
                 ["src/x.js — defines: ONE, TWO\n\nexport const ONE = 1, TWO = 2;"]
      end
    end

    test "go" do
      src = ~S'''
      package main

      import (
      	"os"
      )

      const Max = 3

      func main() {}
      '''

      assert embed_toplevel(src, "go", "cmd/main.go") ==
               ["cmd/main.go — defines: Max\n\npackage main\n\nconst Max = 3"]
    end

    test "elixir: nested module body, header names the module attributes" do
      src = ~S'''
      defmodule A do
        use Foo
        alias A.B
        @limit 3

        def f, do: 1
      end
      '''

      assert embed_toplevel(src, "elixir", "lib/a.ex") ==
               [
                 "lib/a.ex > A — defines: limit\n\ndefmodule A do\n\n  @limit 3",
                 "lib/a.ex > A\n\nend"
               ]
    end

    test "java" do
      src = ~S'''
      import java.util.List;

      public class A {
        static final int MAX = 3;
        void f() {}
      }
      '''

      assert [imports_only, class_head, _tail] = embed_toplevel(src, "java", "A.java")
      # A chunk of nothing but imports keeps them.
      assert imports_only == "A.java\n\nimport java.util.List;"
      assert class_head =~ "A.java > A — defines: MAX"
    end

    test "ruby" do
      src = ~S'''
      require "json"
      LIMIT = 3

      def f; end
      '''

      assert embed_toplevel(src, "ruby", "lib/a.rb") == ["lib/a.rb — defines: LIMIT\n\nLIMIT = 3"]
    end

    test "same-line imports separated by ; keep their text (python, rust)" do
      for {lang, src} <- [
            {"python", "import os; import sys\n"},
            {"rust", "use a::b; use c::d;\n"}
          ] do
        embeds = embed_toplevel(src, lang, "f")
        assert Enum.any?(embeds, &(&1 =~ ~r/(os|a::b)/)), "#{lang}: #{inspect(embeds)}"
        refute Enum.any?(embeds, &(&1 =~ ~r/\n\n[;\s]*\z/)), "#{lang}: #{inspect(embeds)}"
      end
    end

    test "elixir: same-line aliases leave only the module head, which is content" do
      embeds = embed_toplevel("defmodule A do\n  alias A.B; alias A.C\nend\n", "elixir", "f")
      assert Enum.any?(embeds, &(&1 =~ "defmodule A do"))
    end

    test "a file of only imports keeps them as the embedded text" do
      assert embed_toplevel("import os\nimport sys\n", "python", "init.py") ==
               ["init.py\n\nimport os\nimport sys"]
    end
  end
end
