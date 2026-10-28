defmodule RetrievalNode.Chunking.TreeSitterAttachmentsTest do
  # A definition chunk starts at its leading attachments (wrappers, decorators,
  # doc attributes/comments); see `RetrievalNode.Chunking.Attachments`.
  use ExUnit.Case, async: false

  @moduletag :tree_sitter

  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  defp chunks!(source, language) do
    assert {:ok, chunks} = TSI.chunk(source, language)

    # bytes move between chunks, never overlap or vanish
    chunks
    |> Enum.sort_by(& &1.start_byte)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert a.end_byte <= b.start_byte end)

    for c <- chunks,
        do: assert(c.text == binary_part(source, c.start_byte, c.end_byte - c.start_byte))

    chunks
  end

  defp definition(chunks, breadcrumb) do
    Enum.find(chunks, &(&1.kind != "toplevel" and &1.breadcrumb == breadcrumb)) ||
      flunk(
        "no definition #{breadcrumb} in #{inspect(Enum.map(chunks, &{&1.kind, &1.breadcrumb}))}"
      )
  end

  defp toplevel_text(chunks),
    do: chunks |> Enum.filter(&(&1.kind == "toplevel")) |> Enum.map_join("\n", & &1.text)

  describe "python" do
    test "stacked decorators with arguments attach; no wrapper-only gap remains" do
      src = """
      import os

      @a
      @b(1, key="v")
      def f():
          pass
      """

      chunks = chunks!(src, "python")
      f = definition(chunks, "f")
      assert f.text == "@a\n@b(1, key=\"v\")\ndef f():\n    pass"
      assert f.start_line == 3
      assert toplevel_text(chunks) == "import os"
    end

    test "decorated method and decorated class" do
      src = """
      @dataclass
      class A:
          x = 1

          @property
          def g(self):
              pass

          def h(self):
              pass
      """

      chunks = chunks!(src, "python")
      assert definition(chunks, "A > g").text =~ ~r/\A@property\n\s+def g/
      assert definition(chunks, "A > h").text =~ ~r/\Adef h/

      header = Enum.find(chunks, &(&1.kind == "toplevel" and &1.breadcrumb == "A"))
      assert header.text =~ ~r/\A@dataclass\nclass A:/
    end

    test "doc comment directly above attaches; after a blank line it does not; trailing comment does not" do
      src = """
      x = 1  # trailing
      def a():
          pass

      # separated

      def b():
          pass

      # doc
      @dec
      def c():
          pass
      """

      chunks = chunks!(src, "python")
      assert definition(chunks, "a").text =~ ~r/\Adef a/
      assert definition(chunks, "b").text =~ ~r/\Adef b/
      assert definition(chunks, "c").text =~ ~r/\A# doc\n@dec\ndef c/
      assert toplevel_text(chunks) =~ "# separated"
    end

    test "definitions without attachments are byte-identical to their node" do
      src = "x = 1\n\ndef f(a):\n    return a\n"
      f = definition(chunks!(src, "python"), "f")
      assert {f.start_byte, f.end_byte, f.text} == {7, 29, "def f(a):\n    return a"}
    end
  end

  describe "javascript / typescript" do
    test "export wrappers attach for each definition kind" do
      src = """
      import x from "x";

      export function f() {}
      export default class C {
        m() {}
      }
      export interface I { a: number }
      export type T = string;
      export enum E { A }
      export const k = 1;
      """

      chunks = chunks!(src, "typescript")
      assert definition(chunks, "f").text == "export function f() {}"
      assert definition(chunks, "C > m").text == "m() {}"
      assert definition(chunks, "I").text == "export interface I { a: number }"
      assert definition(chunks, "T").text == "export type T = string;"
      assert definition(chunks, "E").text == "export enum E { A }"

      c_header = Enum.find(chunks, &(&1.kind == "toplevel" and &1.breadcrumb == "C"))
      assert c_header.text =~ ~r/\Aexport default class C/
      # a non-definition export stays in the gap
      assert toplevel_text(chunks) =~ "export const k = 1;"
    end

    test "export default function and javascript exports" do
      chunks = chunks!("// docs\nexport default function g() {}\n", "javascript")
      assert definition(chunks, "g").text == "// docs\nexport default function g() {}"
      assert toplevel_text(chunks) == ""
    end

    test "typescript method decorators and ambient declarations" do
      src = """
      class Foo {
        a = 1;

        // doc
        @dec()
        @other
        m() {}

        n() {}
      }
      declare class Z { m(): void }
      """

      chunks = chunks!(src, "typescript")
      assert definition(chunks, "Foo > m").text == "// doc\n  @dec()\n  @other\n  m() {}"
      assert definition(chunks, "Foo > n").text == "n() {}"
      assert definition(chunks, "Z").text == "declare class Z { m(): void }"
    end

    test "export does not leak onto methods of a non-definition export" do
      src = "export const A = class {\n  m() {}\n};\n"
      chunks = chunks!(src, "javascript")
      assert definition(chunks, "m").text == "m() {}"
    end
  end

  describe "elixir" do
    test "@doc/@spec/@impl attach, a data attribute stays in the gap and in names" do
      src = """
      defmodule A do
        @limit 3
        # note
        @doc "x"
        @spec f() :: :ok
        @impl true
        def f, do: :ok

        @doc false
        defp g, do: 1
      end
      """

      chunks = chunks!(src, "elixir")
      f = definition(chunks, "A > f")
      assert f.text == "# note\n  @doc \"x\"\n  @spec f() :: :ok\n  @impl true\n  def f, do: :ok"
      assert definition(chunks, "A > g").text == "@doc false\n  defp g, do: 1"

      gap = Enum.find(chunks, &(&1.kind == "toplevel" and &1.breadcrumb == "A"))
      assert gap.text =~ "@limit 3"
      assert "limit" in gap.names
      refute gap.text =~ "@doc"
    end
  end

  describe "doc comments" do
    test "go" do
      src = "package p\n\n// F does it.\n// More.\nfunc F() {}\n\n// sep\n\nfunc G() {}\n"
      chunks = chunks!(src, "go")
      assert definition(chunks, "F").text == "// F does it.\n// More.\nfunc F() {}"
      assert definition(chunks, "G").text == "func G() {}"
    end

    test "ruby" do
      src = "# doc\ndef a\nend\n\n# sep\n\ndef b\nend\n"
      chunks = chunks!(src, "ruby")
      assert definition(chunks, "a").text == "# doc\ndef a\nend"
      assert definition(chunks, "b").text == "def b\nend"
    end

    test "java: javadoc attaches, annotations are already inside the declaration" do
      src = """
      class A {
        /** doc */
        @Override
        public void f() {}

        // sep

        void g() {}
      }
      """

      chunks = chunks!(src, "java")
      assert definition(chunks, "A > f").text == "/** doc */\n  @Override\n  public void f() {}"
      assert definition(chunks, "A > g").text == "void g() {}"
    end

    test "rust: attributes and outer doc comments attach; plain and inner comments do not" do
      src = """
      /// doc
      /// more
      #[derive(Debug)]
      struct S;

      //! inner
      // plain
      fn f() {}

      /** block doc */
      fn g() {}
      """

      chunks = chunks!(src, "rust")
      assert definition(chunks, "S").text == "/// doc\n/// more\n#[derive(Debug)]\nstruct S;"
      assert definition(chunks, "f").text == "fn f() {}"
      assert definition(chunks, "g").text == "/** block doc */\nfn g() {}"
      assert toplevel_text(chunks) =~ "//! inner"
    end

    test "javascript doc comment and blank-line separation" do
      src = "/** a */\nfunction a() {}\n\n// b\n\nfunction b() {}\n"
      chunks = chunks!(src, "javascript")
      assert definition(chunks, "a").text == "/** a */\nfunction a() {}"
      assert definition(chunks, "b").text == "function b() {}"
    end
  end

  describe "ownership" do
    test "boundaries nested inside a decorator argument are not separate chunks" do
      src = "class C {\n  @dec({ helper() {} })\n  m() {}\n}\n"
      chunks = chunks!(src, "typescript")
      assert definition(chunks, "C > m").text == "@dec({ helper() {} })\n  m() {}"
      refute Enum.any?(chunks, &(&1.breadcrumb =~ "helper"))
    end

    test "boundaries nested inside a wrapper's decorator are not separate chunks" do
      src = "@deco({ hook() {} })\nexport class C {}\n"
      chunks = chunks!(src, "typescript")
      assert definition(chunks, "C").text == src |> String.trim_trailing()
      refute Enum.any?(chunks, &(&1.breadcrumb =~ "hook"))
    end

    test "python decorators with lambdas attach without extra chunks" do
      src = "@dec(lambda x: x)\n@other\ndef f():\n    pass\n"
      chunks = chunks!(src, "python")
      assert Enum.map(chunks, & &1.kind) == ["function_definition"]
      assert hd(chunks).text == String.trim_trailing(src)
    end

    test "elixir attribute values holding anonymous functions attach without extra chunks" do
      src = "defmodule A do\n  @doc fn -> 1 end\n  def f, do: 1\nend\n"
      chunks = chunks!(src, "elixir")
      assert definition(chunks, "A > f").text =~ ~r/\A@doc fn -> 1 end\n\s+def f/
    end
  end

  describe "ownership when the scan stops short of the lead" do
    test "comment between export and class" do
      src = "@deco({ hook() {} })\nexport /* note */ class C {}\n"
      chunks = chunks!(src, "typescript")
      assert [c] = chunks
      assert c.text == String.trim_trailing(src)
    end

    test "block comment after the decorator" do
      src = "@deco({ hook() {} }) /* note */\nexport class C {}\n"
      chunks = chunks!(src, "typescript")
      assert [c] = chunks
      assert c.text == String.trim_trailing(src)
    end

    test "typescript method with a comment after its decorator" do
      src = "class C {\n  @dec({ h() {} }) /* c */ m() {}\n}\n"
      chunks = chunks!(src, "typescript")

      assert Enum.sort(for c <- chunks, c.kind != "toplevel", do: c.breadcrumb) == [
               "C > h",
               "C > m"
             ]
    end

    test "python decorator followed by a trailing comment" do
      src = "@deco(lambda: 1)  # c\ndef f():\n    pass\n"
      chunks = chunks!(src, "python")
      assert [c] = chunks
      assert c.text == String.trim_trailing(src)
    end
  end

  describe "standalone comments" do
    test "a comment after code on the container's header line stays with the header" do
      for {lang, src} <- [
            {"java", "class A { // class note\n  void f() {}\n}\n"},
            {"javascript", "class A { // class note\n  f() {}\n}\n"},
            {"typescript", "class A { // class note\n  f() {}\n}\n"},
            {"javascript", "class A { /* note */\n  f() {}\n}\n"}
          ] do
        chunks = chunks!(src, lang)
        f = definition(chunks, "A > f")
        refute f.text =~ "note", lang
        assert Enum.find(chunks, &(&1.kind == "toplevel" and &1.breadcrumb == "A")).text =~ "note"
      end
    end

    test "a comment on its own line still attaches" do
      chunks = chunks!("class A {\n  // own line\n  f() {}\n}\n", "javascript")
      assert definition(chunks, "A > f").text == "// own line\n  f() {}"
    end
  end
end
