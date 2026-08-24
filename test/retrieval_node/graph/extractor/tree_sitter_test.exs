defmodule RetrievalNode.Graph.Extractor.TreeSitterTest do
  use ExUnit.Case, async: true

  # Real tree-sitter parsing loads the NIF; excluded by default (mirrors
  # RetrievalNode.Chunking.TreeSitterImplTest's "real AST chunking" describe).
  # Run with `mix test --include integration`.
  @moduletag :integration

  alias RetrievalNode.Graph.Extractor.TreeSitter, as: GraphTS
  alias TreeSitterLanguagePack, as: TS

  defp parse(source, language) do
    parser = TS.parser_new()
    {:ok, {}} = TS.parser_set_language(parser, language)
    parser |> TS.parser_parse(source) |> TS.tree_root_node()
  end

  defp extract(source, language) do
    root = parse(source, language)
    {:ok, result} = GraphTS.extract({root, source}, language, [])
    result
  end

  describe "python" do
    @src """
    class Payment:
        def process(self):
            return self.helper()


    def helper():
        return 1


    import os
    import os.path as osp
    from collections import OrderedDict
    """

    test "entities: class, method-inside-class, and top-level function" do
      %{entities: entities} = extract(@src, "python")

      assert %{qualified_name: "Payment", kind: :class} = find(entities, "Payment")

      assert %{qualified_name: "Payment.process", kind: :method} =
               find(entities, "Payment.process")

      assert %{qualified_name: "helper", kind: :function} = find(entities, "helper")
    end

    test "qualified-callee resolution: self.helper() -> \"helper\", scoped to Payment.process" do
      %{references: refs} = extract(@src, "python")

      assert %{name: "helper", kind: :call, from: "Payment.process"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "imports: plain, aliased (real module name, not the alias), and from-import" do
      %{references: refs} = extract(@src, "python")
      imports = Enum.filter(refs, &(&1.kind == :import))

      assert Enum.any?(imports, &(&1.name == "os" and &1.from == nil))
      assert Enum.any?(imports, &(&1.name == "os.path" and &1.from == nil))
      assert Enum.any?(imports, &(&1.name == "collections" and &1.from == nil))
    end
  end

  describe "javascript" do
    @src """
    class Foo {
      bar() {
        return baz();
      }
    }

    function baz() {
      return 1;
    }

    const anon = () => {
      return helper();
    };

    import { thing } from "./thing";
    """

    test "entities: class, method-inside-class, top-level function; no entity for the anonymous arrow" do
      %{entities: entities} = extract(@src, "javascript")

      assert %{qualified_name: "Foo", kind: :class} = find(entities, "Foo")
      assert %{qualified_name: "Foo.bar", kind: :method} = find(entities, "Foo.bar")
      assert %{qualified_name: "baz", kind: :function} = find(entities, "baz")

      # The arrow function has no "name" field, so it is not a definition node
      # at all: no entity is emitted for it under any name.
      refute Enum.any?(entities, &(&1.qualified_name in ["anon", "arrow_function"]))
    end

    test "calls scoped correctly: inside a method vs. inside the anonymous arrow (from = nil)" do
      %{references: refs} = extract(@src, "javascript")

      assert %{name: "baz", kind: :call, from: "Foo.bar"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "baz"))

      # helper() is called inside the anonymous arrow, which is not itself an
      # entity, so `from` falls through to the nearest NAMED enclosing
      # definition — none here, so nil.
      assert %{name: "helper", kind: :call, from: nil} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "import: source string with quotes stripped" do
      %{references: refs} = extract(@src, "javascript")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "./thing" and &1.from == nil))
    end
  end

  describe "go" do
    @src """
    package main

    import "fmt"

    type Point struct {
    \tX int
    }

    func (p Point) Distance() int {
    \treturn fmt.Println("hi")
    }

    func main() {
    \tfmt.Println("hello")
    }
    """

    test "entities: struct (class-like via nested type_spec name) and top-level functions" do
      %{entities: entities} = extract(@src, "go")

      assert %{qualified_name: "Point", kind: :class} = find(entities, "Point")
      assert %{qualified_name: "main", kind: :function} = find(entities, "main")

      # Go methods are declared via a receiver, not nested inside their type's
      # AST node, so the "immediately-enclosing container is class-like"
      # :method rule never fires for Go: Distance is top-level in the tree and
      # comes out :function, not :method.
      assert %{qualified_name: "Distance", kind: :function} = find(entities, "Distance")
    end

    test "qualified-callee resolution: fmt.Println() -> \"Println\", scoped per call site" do
      %{references: refs} = extract(@src, "go")
      calls = Enum.filter(refs, &(&1.kind == :call and &1.name == "Println"))

      assert length(calls) == 2
      assert Enum.any?(calls, &(&1.from == "Distance"))
      assert Enum.any?(calls, &(&1.from == "main"))
    end

    test "import: quoted path stripped" do
      %{references: refs} = extract(@src, "go")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "fmt" and &1.from == nil))
    end
  end

  describe "ruby" do
    @src """
    require "json"

    class Greeter
      def hello
        puts(helper())
      end

      def self.static_hello
        1
      end
    end

    def helper
      42
    end
    """

    test "entities: class, method and singleton_method-inside-class, top-level method" do
      %{entities: entities} = extract(@src, "ruby")

      assert %{qualified_name: "Greeter", kind: :class} = find(entities, "Greeter")
      assert %{qualified_name: "Greeter.hello", kind: :method} = find(entities, "Greeter.hello")

      assert %{qualified_name: "Greeter.static_hello", kind: :method} =
               find(entities, "Greeter.static_hello")

      assert %{qualified_name: "helper", kind: :function} = find(entities, "helper")
    end

    test "calls scoped to the enclosing method" do
      %{references: refs} = extract(@src, "ruby")

      assert %{name: "puts", kind: :call, from: "Greeter.hello"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "puts"))

      assert %{name: "helper", kind: :call, from: "Greeter.hello"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "require is classified :import (not :call), content of its string argument" do
      %{references: refs} = extract(@src, "ruby")

      assert %{name: "json", kind: :import, from: nil} =
               Enum.find(refs, &(&1.name == "json"))

      refute Enum.any?(refs, &(&1.name == "require"))
    end
  end

  describe "java" do
    @src """
    import java.util.List;

    class Calculator {
        int add(int a, int b) {
            return this.helper(a, b);
        }

        int helper(int a, int b) {
            return a + b;
        }
    }
    """

    test "entities: class and methods-inside-class" do
      %{entities: entities} = extract(@src, "java")

      assert %{qualified_name: "Calculator", kind: :class} = find(entities, "Calculator")
      assert %{qualified_name: "Calculator.add", kind: :method} = find(entities, "Calculator.add")

      assert %{qualified_name: "Calculator.helper", kind: :method} =
               find(entities, "Calculator.helper")
    end

    test "qualified-callee resolution: this.helper(a, b) -> \"helper\", scoped to Calculator.add" do
      %{references: refs} = extract(@src, "java")

      assert %{name: "helper", kind: :call, from: "Calculator.add"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "import: scoped identifier text" do
      %{references: refs} = extract(@src, "java")

      assert Enum.any?(
               refs,
               &(&1.kind == :import and &1.name == "java.util.List" and &1.from == nil)
             )
    end
  end

  describe "oversized symbols" do
    # Mirrors @max_symbol_bytes in the extractor: identifiers past the cap are
    # minified/generated junk and would blow the entities unique btree index
    # row limit downstream — they must never be emitted.
    test "definitions and callees longer than the cap are skipped; normal ones survive" do
      long = String.duplicate("x", 300)

      src = """
      def #{long}():
          return 1


      def ok():
          return #{long}()
      """

      %{entities: entities, references: refs} = extract(src, "python")

      assert Enum.any?(entities, &(&1.qualified_name == "ok"))
      refute Enum.any?(entities, &(byte_size(&1.qualified_name) > 256))
      refute Enum.any?(refs, &(byte_size(&1.name) > 256))
    end
  end

  defp find(entities, qualified_name),
    do: Enum.find(entities, &(&1.qualified_name == qualified_name))
end
