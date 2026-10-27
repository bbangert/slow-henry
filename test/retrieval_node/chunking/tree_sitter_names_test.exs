defmodule RetrievalNode.Chunking.TreeSitterNamesTest do
  # `names` on toplevel (gap) chunks: the names bound by top-level code, read
  # from the AST. async: false — shares the application-owned ChunkTaskSupervisor
  # with the other tree-sitter chunker tests.
  use ExUnit.Case, async: false

  @moduletag :tree_sitter

  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  defp chunks!(source, lang) do
    assert {:ok, chunks} = TSI.chunk(source, lang)
    chunks
  end

  defp toplevel(chunks), do: Enum.filter(chunks, &(&1.kind == "toplevel"))

  defp names_at(chunks, breadcrumb) do
    chunks
    |> toplevel()
    |> Enum.filter(&(&1.breadcrumb == breadcrumb))
    |> Enum.flat_map(& &1.names)
  end

  describe "per-language bindings" do
    test "python: assignments, annotated, augmented, tuples, chained; not attributes/subscripts" do
      src = ~S'''
      import os

      __all__ = ["a"]
      X: int = 3
      A, b = 1, 2
      Y += 1
      self.z = 1
      d["k"] = 2
      p = q = 3
      A = 4

      def f():
          hidden = 1
      '''

      assert names_at(chunks!(src, "python"), "") == ~w(__all__ X A b Y p q)
    end

    test "python: class-body constants land on the class's gap chunk" do
      src = ~S'''
      class C:
          K = 1
          J: int = 2

          def f(self):
              inner = 1
      '''

      chunks = chunks!(src, "python")
      assert names_at(chunks, "C") == ~w(K J)
      assert names_at(chunks, "") == []
    end

    test "javascript: declarators, destructuring, export, customElements.define; not nested" do
      src = ~S'''
      export const a = 1, b = 2;
      let {x, y: z, w = 3} = o;
      var [p, q] = r;
      customElements.define('my-el', Foo);
      foo(() => { const hidden = 1 });

      function f() { const inner = 1; }
      '''

      assert names_at(chunks!(src, "javascript"), "") ==
               ["a", "b", "x", "z", "w", "p", "q", "customElements:my-el"]
    end

    test "typescript: exported and ambient consts" do
      src = ~S'''
      export const a: number = 1;
      declare const d: string;
      type T = { x: number };
      '''

      assert names_at(chunks!(src, "typescript"), "") == ~w(a d)
    end

    test "go: var and const specs, grouped or not" do
      src = ~S'''
      package main

      var a = 1

      var (
      	b int
      	c, d = 1, 2
      )

      const E = 3

      const (
      	F = iota
      	G
      )

      func f() { inner := 1 }
      '''

      assert names_at(chunks!(src, "go"), "") == ~w(a b c d E F G)
    end

    test "rust: const and static items, including in impl and mod bodies" do
      src = ~S'''
      const A: u32 = 1;
      static B: u32 = 2;

      struct S;

      impl S {
          const D: u32 = 1;
          fn g(&self) {}
      }
      '''

      chunks = chunks!(src, "rust")
      assert names_at(chunks, "") == ~w(A B)
      assert names_at(chunks, "impl_item") == ~w(D)
    end

    test "ruby: constant assignments, not locals or scoped constants" do
      src = ~S'''
      FOO = 1
      Bar, Baz = 1, 2
      x = 2
      A::B = 1

      class K
        LIMIT = 3
        def f; end
      end
      '''

      chunks = chunks!(src, "ruby")
      assert names_at(chunks, "") == ~w(FOO Bar Baz)
      assert names_at(chunks, "K") == ~w(LIMIT)
    end

    test "java: field declarators in class bodies" do
      src = ~S'''
      class K {
        int a = 1, b;
        static final String C = "x";
        void f() { int local = 1; }
      }
      '''

      assert names_at(chunks!(src, "java"), "K") == ~w(a b C)
    end

    test "elixir: module attributes minus doc/typing/directive attributes" do
      src = ~S'''
      defmodule M do
        @moduledoc "x"
        @foo 1
        @bar
        @doc "y"
        @spec f() :: :ok
        @impl true
        @foo 2
        use Something
        def f, do: @foo
      end

      @top 3
      '''

      chunks = chunks!(src, "elixir")
      assert names_at(chunks, "M") == ~w(foo bar)
      assert names_at(chunks, "") == ~w(top)
    end
  end

  describe "piece assignment and limits" do
    test "a gap split into several pieces gives each name to the piece containing it" do
      body = String.duplicate("x", 150)

      src =
        for i <- 1..120, into: "" do
          "NAME_#{i} = \"#{body}\"\n\n"
        end

      pieces = src |> chunks!("python") |> toplevel()
      assert length(pieces) > 1

      for piece <- pieces, name <- piece.names do
        assert String.contains?(piece.text, name <> " =")
      end

      all = Enum.flat_map(pieces, & &1.names)
      assert Enum.sort(all) == Enum.sort(for i <- 1..120, do: "NAME_#{i}")
      assert Enum.all?(pieces, &(length(&1.names) <= 20))
    end

    test "names are capped at 20 and deduped" do
      src = Enum.map_join(1..30, "\n", &"V#{&1} = #{&1}") <> "\nV1 = 0\n"

      assert [%{names: names}] = src |> chunks!("python") |> toplevel()
      assert names == for(i <- 1..20, do: "V#{i}")
    end

    test "no bindings gives an empty list; definition chunks carry no names key" do
      src = "import os\n\ndef f():\n    return 1\n"
      chunks = chunks!(src, "python")

      assert [%{names: []}] = toplevel(chunks)
      assert [definition] = Enum.reject(chunks, &(&1.kind == "toplevel"))
      refute Map.has_key?(definition, :names)
    end
  end
end
