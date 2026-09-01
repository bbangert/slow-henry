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

    test "self.helper() -> \"Payment.helper\": self-receiver scoped to the enclosing class" do
      %{references: refs} = extract(@src, "python")

      assert %{name: "Payment.helper", kind: :call, from: "Payment.process"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Payment.helper"))
    end

    test "other.helper() -> \"helper\": non-self receiver stays unscoped best-effort" do
      %{references: refs} =
        extract(
          """
          class Payment:
              def process(self, other):
                  return other.helper()
          """,
          "python"
        )

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

    test "from-import records both the module and each imported symbol (aliased -> original name)" do
      %{references: refs} =
        extract("from a.b import Klass, func as f\n", "python")

      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert "a.b" in names
      assert "Klass" in names
      assert "func" in names
      refute "f" in names
    end

    test "wildcard from-import records only the module, no symbol" do
      %{references: refs} = extract("from x import *\n", "python")
      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert names == ["x"]
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

    test "named import: records the module plus default and named symbols (alias -> original name)" do
      %{references: refs} =
        extract("import Default, { named, orig as alias } from \"./mod\";\n", "javascript")

      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert "./mod" in names
      assert "Default" in names
      assert "named" in names
      assert "orig" in names
      refute "alias" in names
    end

    test "namespace import records only the module, no symbol" do
      %{references: refs} = extract("import * as ns from \"y\";\n", "javascript")
      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert names == ["y"]
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

    test "self.helper() -> \"Greeter.helper\": self-receiver scoped to the enclosing class" do
      %{references: refs} =
        extract(
          """
          class Greeter
            def hello
              self.helper()
            end

            def helper
              1
            end
          end
          """,
          "ruby"
        )

      assert %{name: "Greeter.helper", kind: :call, from: "Greeter.hello"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Greeter.helper"))
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

    test "this.helper(a, b) -> \"Calculator.helper\": self-receiver scoped to the enclosing class" do
      %{references: refs} = extract(@src, "java")

      assert %{name: "Calculator.helper", kind: :call, from: "Calculator.add"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Calculator.helper"))
    end

    test "bare helper(a, b) (implicit this, no explicit receiver) stays unscoped" do
      %{references: refs} =
        extract(
          """
          class Calculator {
              int add(int a, int b) {
                  return helper(a, b);
              }

              int helper(int a, int b) {
                  return a + b;
              }
          }
          """,
          "java"
        )

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

  describe "typescript" do
    @src """
    interface Shape {
      area(): number;
    }

    class Circle {
      area(): number {
        return this.helper();
      }

      helper(): number {
        return 1;
      }
    }

    function standalone(): number {
      return helper2();
    }

    function helper2(): number {
      return 2;
    }

    import { thing } from "./thing";
    """

    test "entities: interface (class-like) and class, method-inside-class, top-level functions" do
      %{entities: entities} = extract(@src, "typescript")

      assert %{qualified_name: "Shape", kind: :class} = find(entities, "Shape")
      assert %{qualified_name: "Circle", kind: :class} = find(entities, "Circle")
      assert %{qualified_name: "Circle.area", kind: :method} = find(entities, "Circle.area")
      assert %{qualified_name: "Circle.helper", kind: :method} = find(entities, "Circle.helper")
      assert %{qualified_name: "standalone", kind: :function} = find(entities, "standalone")
      assert %{qualified_name: "helper2", kind: :function} = find(entities, "helper2")
    end

    test "this.helper() -> \"Circle.helper\": self-receiver scoped to the enclosing class; a bare call scoped to its top-level function" do
      %{references: refs} = extract(@src, "typescript")

      assert %{name: "Circle.helper", kind: :call, from: "Circle.area"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Circle.helper"))

      assert %{name: "helper2", kind: :call, from: "standalone"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper2"))
    end

    test "foo.helper() at module level (no enclosing class) stays unscoped best-effort" do
      %{references: refs} =
        extract(
          """
          function standalone(): number {
            return foo.helper();
          }
          """,
          "typescript"
        )

      assert %{name: "helper", kind: :call, from: "standalone"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "import: source string with quotes stripped" do
      %{references: refs} = extract(@src, "typescript")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "./thing" and &1.from == nil))
    end

    test "named import: records the module plus default and named symbols (alias -> original name)" do
      %{references: refs} =
        extract("import Default, { named, orig as alias } from \"./mod\";\n", "typescript")

      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert "./mod" in names
      assert "Default" in names
      assert "named" in names
      assert "orig" in names
      refute "alias" in names
    end
  end

  describe "rust" do
    @src """
    struct Point {
        x: i32,
    }

    impl Point {
        fn distance(&self) -> i32 {
            self.helper()
        }

        fn helper(&self) -> i32 {
            1
        }
    }

    fn main() {
        helper_fn();
    }

    fn helper_fn() -> i32 {
        2
    }

    use std::collections::HashMap;
    """

    test "entities: struct, impl block (named via its \"type\" field), and methods-inside-impl, top-level function" do
      %{entities: entities} = extract(@src, "rust")

      assert %{qualified_name: "Point", kind: :class} = find(entities, "Point")
      assert %{qualified_name: "Point.distance", kind: :method} = find(entities, "Point.distance")
      assert %{qualified_name: "Point.helper", kind: :method} = find(entities, "Point.helper")
      assert %{qualified_name: "main", kind: :function} = find(entities, "main")
      assert %{qualified_name: "helper_fn", kind: :function} = find(entities, "helper_fn")
    end

    test "self.helper() -> \"Point.helper\": self-receiver scoped to the enclosing impl block; a bare call scoped to main" do
      %{references: refs} = extract(@src, "rust")

      assert %{name: "Point.helper", kind: :call, from: "Point.distance"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Point.helper"))

      assert %{name: "helper_fn", kind: :call, from: "main"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper_fn"))
    end

    test "import: use_declaration argument text" do
      %{references: refs} = extract(@src, "rust")

      assert Enum.any?(
               refs,
               &(&1.kind == :import and &1.name == "std::collections::HashMap" and
                   &1.from == nil)
             )
    end
  end

  describe "elixir" do
    @src """
    defmodule Payment.Processor do
      @moduledoc "docs"

      alias Foo.Bar, as: B
      import Ecto.Query
      use GenServer
      require Logger

      def process(order) do
        B.run(order)
        helper(order)
      end

      defp helper(o), do: o

      def init, do: :ok

      def guarded(x) when x > 1 do
        x
      end

      @x String.trim("y")
    end
    """

    test "entities: module, def/defp-inside-module as :function with qualified names" do
      %{entities: entities} = extract(@src, "elixir")

      assert %{qualified_name: "Payment.Processor", kind: :module} =
               find(entities, "Payment.Processor")

      assert %{qualified_name: "Payment.Processor.process", kind: :function} =
               find(entities, "Payment.Processor.process")

      assert %{qualified_name: "Payment.Processor.helper", kind: :function} =
               find(entities, "Payment.Processor.helper")
    end

    test "zero-arity no-paren def is named correctly" do
      %{entities: entities} = extract(@src, "elixir")

      assert %{qualified_name: "Payment.Processor.init", kind: :function} =
               find(entities, "Payment.Processor.init")
    end

    test "a when-guard def is named correctly (not \"guarded(x) when x > 1\")" do
      %{entities: entities} = extract(@src, "elixir")

      assert %{qualified_name: "Payment.Processor.guarded", kind: :function} =
               find(entities, "Payment.Processor.guarded")
    end

    test "bare and dot-qualified calls scoped to the enclosing def" do
      %{references: refs} = extract(@src, "elixir")

      assert %{name: "helper", kind: :call, from: "Payment.Processor.process"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))

      assert %{name: "run", kind: :call, from: "Payment.Processor.process"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "run"))
    end

    test "a def's own head is not walked as a call: no spurious self-call from process to process" do
      %{references: refs} = extract(@src, "elixir")

      refute Enum.any?(
               refs,
               &(&1.kind == :call and &1.name == "process" and
                   &1.from == "Payment.Processor.process")
             )
    end

    test "a when-guard def's head and guard are not walked as calls, but its body still is" do
      %{references: refs} =
        extract(
          """
          defmodule Payment.Processor do
            def guarded(x) when is_binary(x) do
              helper(x)
            end
          end
          """,
          "elixir"
        )

      refute Enum.any?(refs, &(&1.kind == :call and &1.name == "guarded"))
      refute Enum.any?(refs, &(&1.kind == :call and &1.name == "is_binary"))

      assert %{name: "helper", kind: :call, from: "Payment.Processor.guarded"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "keyword `do:` form still walks its body: defp x(a), do: helper(a) finds the call" do
      %{references: refs} =
        extract(
          """
          defmodule Payment.Processor do
            defp x(a), do: helper(a)
          end
          """,
          "elixir"
        )

      assert %{name: "helper", kind: :call, from: "Payment.Processor.x"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "alias/import/use/require all become :import refs named by the full module text" do
      %{references: refs} = extract(@src, "elixir")
      imports = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert "Foo.Bar" in imports
      assert "Ecto.Query" in imports
      assert "GenServer" in imports
      assert "Logger" in imports
    end

    test "@moduledoc does not produce a call ref, but a call nested in an attribute value is found" do
      %{references: refs} = extract(@src, "elixir")

      refute Enum.any?(refs, &(&1.kind == :call and &1.name == "moduledoc"))
      refute Enum.any?(refs, &(&1.kind == :call and &1.name == "x"))

      assert %{name: "trim", kind: :call, from: "Payment.Processor"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "trim"))
    end

    test "typespec attributes (@spec/@callback/@type) are never walked as calls, unlike other attributes" do
      %{references: refs} =
        extract(
          """
          defmodule M do
            @spec f(binary()) :: :ok
            def f(x), do: g(x)

            @callback cb(term()) :: :ok

            @type t :: map()

            @custom String.trim("a")
          end
          """,
          "elixir"
        )

      call_names = refs |> Enum.filter(&(&1.kind == :call)) |> Enum.map(& &1.name)

      assert %{name: "g", kind: :call, from: "M.f"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "g"))

      assert %{name: "trim", kind: :call, from: "M"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "trim"))

      refute "f" in call_names
      refute "binary" in call_names
      refute "cb" in call_names
      refute "term" in call_names
      refute "map" in call_names
    end

    test "alias braces form best-effort: alias Foo.{Bar, Baz} records a single \"Foo\" import ref" do
      %{references: refs} = extract("alias Foo.{Bar, Baz}\n", "elixir")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "Foo"))
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
