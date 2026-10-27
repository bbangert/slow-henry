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

  describe "every identifier bound by a target pattern" do
    test "python: starred, nested and parenthesized targets; not starred attributes" do
      src = ~S'''
      head, *tail = v
      (a, (b, *c)), [d, e] = x
      *obj.attr, f = y
      (g) = 1
      [h, *i] = z
      '''

      assert names_at(chunks!(src, "python"), "") == ~w(head tail a b c d e f g h i)
    end

    for lang <- ~w(javascript typescript) do
      test "#{lang}: rest, defaults, nested and renamed patterns" do
        src = ~S'''
        const {a, ...rest} = o;
        const [x, ...ys] = arr;
        const {p: {q = 1}, r: [s, t]} = u;
        const {k: l = 5} = m;
        let [m1 = 2, [n1, ...o1]] = w;
        '''

        assert names_at(chunks!(src, unquote(lang)), "") ==
                 ~w(a rest x ys q s t l m1 n1 o1)
      end
    end

    test "go: several names per spec" do
      src = ~S'''
      package main

      var a, b = 1, 2

      var (
      	c, d int
      )

      const X, Y = 1, 2
      '''

      assert names_at(chunks!(src, "go"), "") == ~w(a b c d X Y)
    end
  end

  describe "declaration forms and structural matching" do
    test "ruby: chained and operator assignments bind every constant" do
      src = "FOO = BAR = 1\nA, B = C = 1, 2\nBAZ ||= 3\nlocal = OTHER = 4\n"
      assert names_at(chunks!(src, "ruby"), "") == ~w(FOO BAR A B C BAZ OTHER)
    end

    test "java: interface constants and enum constants (enum with methods is a container)" do
      src = ~S'''
      interface I {
        int X = 1;
        void f();
      }

      enum E {
        A, B(1);
        int c = 1;
        void g() {}
      }
      '''

      chunks = chunks!(src, "java")
      assert names_at(chunks, "I") == ~w(X)
      assert names_at(chunks, "E") == ~w(A B c)
    end

    test "rust and python type aliases" do
      assert names_at(chunks!("type T = u32;\nconst A: u8 = 1;\n", "rust"), "") == ~w(T A)
      assert names_at(chunks!("type X = int\nY = 1\n", "python"), "") == ~w(X Y)
    end

    for lang <- ~w(javascript typescript) do
      test "#{lang}: customElements.define is matched structurally, not by spelling" do
        src = ~S'''
        customElements . define('a-el', A);
        customElements
          // comment
          .define(
            // another
            "b-el", B);
        window.customElements.define('no-el', C);
        customElements.define(tag, D);
        const a = b = 1;
        '''

        assert names_at(chunks!(src, unquote(lang)), "") ==
                 ["customElements:a-el", "customElements:b-el", "a"]
      end
    end
  end

  describe "customElements tag literal is fully decoded" do
    for lang <- ~w(javascript typescript) do
      test "#{lang}: escapes, all-escaped, template and undecodable tags" do
        src = ~S'''
        customElements.define("my\u002del", A);
        customElements.define("\x61\x2db", B);
        customElements.define(`tpl-el`, C);
        customElements.define(`tpl-${x}`, D);
        customElements.define("", E);
        customElements.define("bad\uD800", F);
        '''

        assert names_at(chunks!(src, unquote(lang)), "") ==
                 ["customElements:my-el", "customElements:a-b", "customElements:tpl-el"]
      end
    end
  end

  describe "piece assignment and limits" do
    test "thousands of bindings interleaved with definitions get exact per-piece names" do
      src =
        for i <- 1..2000, into: "" do
          "V#{i} = #{i}\n\ndef f#{i}():\n    return #{i}\n\n"
        end

      pieces = src |> chunks!("python") |> toplevel()
      assert length(pieces) == 2000
      assert Enum.map(pieces, & &1.names) == for(i <- 1..2000, do: ["V#{i}"])
    end

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
