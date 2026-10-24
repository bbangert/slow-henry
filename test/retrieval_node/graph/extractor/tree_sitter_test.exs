defmodule RetrievalNode.Graph.Extractor.TreeSitterTest do
  use ExUnit.Case, async: true

  # Real tree-sitter parsing loads the NIF and needs cached grammars; excluded by
  # default (see test_helper.exs). CI prefetches and runs it; locally run
  # `mix test --include tree_sitter`.
  @moduletag :tree_sitter

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
    assert_invariants!(result)
    result
  end

  @max_items 10_000
  @symbol_forbidden [
    {"`::`", "::"},
    {"a double quote", "\""},
    {"a single quote", "'"},
    {"a backtick", "`"},
    {"`(`", "("},
    {"`)`", ")"},
    {"`..`", ".."}
  ]
  @import_forbidden [
    {"a double quote", "\""},
    {"a single quote", "'"},
    {"a backtick", "`"},
    {"`(`", "("},
    {"`)`", ")"}
  ]

  # Invariants every extraction result must satisfy, whatever the source.
  defp assert_invariants!(%{entities: entities, references: references}) do
    total = length(entities) + length(references)
    assert total <= @max_items, "cap: #{total} entities+references exceeds #{@max_items}"

    for %{qualified_name: name} = entity <- entities do
      assert_symbol!(name, "entity #{inspect(entity)} qualified_name", @symbol_forbidden, true)
    end

    qnames = MapSet.new(entities, & &1.qualified_name)

    for %{name: name, kind: kind, from: from} = ref <- references do
      if kind == :import do
        assert_symbol!(name, "import #{inspect(ref)} name", @import_forbidden, false)
      else
        assert_symbol!(name, "reference #{inspect(ref)} name", @symbol_forbidden, true)
      end

      assert is_nil(from) or MapSet.member?(qnames, from),
             "from validity: reference #{inspect(ref)} has `from` #{inspect(from)} " <>
               "that is not the qualified_name of any entity in the result"
    end

    :ok
  end

  defp assert_symbol!(name, label, forbidden, dotted?) do
    assert is_binary(name) and name != "",
           "#{label}: must be a non-empty string, got #{inspect(name)}"

    assert not String.match?(name, ~r/\s/),
           "#{label}: must not contain whitespace, got #{inspect(name)}"

    assert not String.match?(name, ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u),
           "#{label}: must not contain control characters, got #{inspect(name)}"

    for {desc, bad} <- forbidden do
      assert not String.contains?(name, bad),
             "#{label}: must not contain #{desc}, got #{inspect(name)}"
    end

    if dotted? do
      assert not (String.starts_with?(name, ".") or String.ends_with?(name, ".")),
             "#{label}: must not start or end with `.`, got #{inspect(name)}"
    end
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

    test "nested function rebinds this (bare callee); nested arrow inherits it" do
      %{references: refs} =
        extract(
          """
          class C {
            m(other) {
              function cb() { this.helper(); }
              const arrow = () => { this.viaArrow(); };
              const fe = function () { this.viaExpr(); };
              cb.call(other);
            }
          }
          """,
          "javascript"
        )

      names = refs |> Enum.filter(&(&1.kind == :call)) |> Enum.map(& &1.name)
      assert "helper" in names
      assert "viaExpr" in names
      assert "C.viaArrow" in names
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

    test "entities: struct (class-like via nested type_spec name), receiver-qualified method, top-level function" do
      %{entities: entities} = extract(@src, "go")

      assert %{qualified_name: "Point", kind: :class} = find(entities, "Point")
      assert %{qualified_name: "main", kind: :function} = find(entities, "main")

      # Distance is qualified by its receiver type ("Point.Distance", not
      # bare "Distance") and comes out :method -- resolved from the
      # receiver's `type:` field, not from AST nesting (a go method is never
      # nested inside its receiver type's own node the way a method sits
      # inside a class body in every other class-like language here).
      assert %{qualified_name: "Point.Distance", kind: :method} = find(entities, "Point.Distance")
      refute Enum.any?(entities, &(&1.qualified_name == "Distance"))
    end

    test "qualified-callee resolution: fmt.Println() -> \"Println\", scoped per call site" do
      %{references: refs} = extract(@src, "go")
      calls = Enum.filter(refs, &(&1.kind == :call and &1.name == "Println"))

      assert length(calls) == 2
      assert Enum.any?(calls, &(&1.from == "Point.Distance"))
      assert Enum.any?(calls, &(&1.from == "main"))
    end

    test "import: quoted path stripped" do
      %{references: refs} = extract(@src, "go")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "fmt" and &1.from == nil))
    end

    test "same-named methods on different receiver types no longer collapse into one entity" do
      %{entities: entities, references: refs} =
        extract(
          """
          package main

          type A struct{}
          type B struct{}

          func (a A) Run() {
          \ta.helper()
          }

          func (a A) helper() {
          }

          func (b B) Run() {
          }
          """,
          "go"
        )

      assert %{qualified_name: "A.Run", kind: :method} = find(entities, "A.Run")
      assert %{qualified_name: "B.Run", kind: :method} = find(entities, "B.Run")

      assert %{name: "helper", kind: :call, from: "A.Run"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "helper"))
    end

    test "pointer receiver is unwrapped to its underlying type: func (p *P) Run() -> \"P.Run\"" do
      %{entities: entities} =
        extract(
          """
          package main

          type P struct{}

          func (p *P) Run() {
          }
          """,
          "go"
        )

      assert %{qualified_name: "P.Run", kind: :method} = find(entities, "P.Run")
    end

    test "import: raw-string (backtick) path stripped" do
      %{references: refs} = extract("package main\n\nimport `fmt`\n", "go")

      assert Enum.any?(refs, &(&1.kind == :import and &1.name == "fmt"))
    end

    test "grouped type declaration: each type_spec is its own entity, not just the first" do
      %{entities: entities} =
        extract(
          """
          package main

          type (
          \tA struct{}
          \tB struct{}
          )

          func (b B) Run() {
          }
          """,
          "go"
        )

      assert %{qualified_name: "A", kind: :class} = find(entities, "A")
      assert %{qualified_name: "B", kind: :class} = find(entities, "B")
      assert %{qualified_name: "B.Run", kind: :method} = find(entities, "B.Run")
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

      # An interface member (`method_signature`) is a definition node too --
      # nested directly inside the class-like interface, it comes out
      # :method via the same rule a concrete class method does.
      assert %{qualified_name: "Shape.area", kind: :method} = find(entities, "Shape.area")

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

    test "import: use_declaration argument text (plain path)" do
      %{references: refs} = extract(@src, "rust")

      assert Enum.any?(
               refs,
               &(&1.kind == :import and &1.name == "std::collections::HashMap" and
                   &1.from == nil)
             )
    end

    test "import: use-list emits one ref per concrete path, including deeply nested groups" do
      %{references: refs} = extract("use std::{fs::File, io::{self, Read}};\n", "rust")
      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert "std::fs::File" in names
      # bare `self` inside a nested list resolves to the prefix itself, not
      # a literal "self" segment
      assert "std::io" in names
      assert "std::io::Read" in names
      assert length(names) == 3
    end

    test "import: use-as-clause records the ORIGINAL path, not the alias" do
      %{references: refs} = extract("use std::io::Result as IoResult;\n", "rust")
      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert names == ["std::io::Result"]
      refute "IoResult" in names
    end

    test "import: use-wildcard records the prefix path, not the glob" do
      %{references: refs} = extract("use std::io::*;\n", "rust")
      names = refs |> Enum.filter(&(&1.kind == :import)) |> Enum.map(& &1.name)

      assert names == ["std::io"]
    end

    test "trait impls are scoped <Type>.<Trait>: same-named methods on different traits no longer collapse" do
      %{entities: entities, references: refs} =
        extract(
          """
          struct Foo;

          impl std::fmt::Display for Foo {
              fn fmt(&self) {
                  self.helper()
              }
          }

          impl Debug for Foo {
              fn fmt(&self) {}
          }

          impl Foo {
              fn helper(&self) {}
          }
          """,
          "rust"
        )

      # path trait (`std::fmt::Display`) resolves to its rightmost segment
      assert %{qualified_name: "Foo.Display", kind: :class} = find(entities, "Foo.Display")

      assert %{qualified_name: "Foo.Display.fmt", kind: :method} =
               find(entities, "Foo.Display.fmt")

      assert %{qualified_name: "Foo.Debug", kind: :class} = find(entities, "Foo.Debug")
      assert %{qualified_name: "Foo.Debug.fmt", kind: :method} = find(entities, "Foo.Debug.fmt")

      refute Enum.any?(entities, &(&1.qualified_name == "Foo.fmt"))

      # the inherent impl (no trait: field) keeps the bare <Type> scope
      assert %{qualified_name: "Foo", kind: :class} = find(entities, "Foo")
      assert %{qualified_name: "Foo.helper", kind: :method} = find(entities, "Foo.helper")

      # self-receiver resolves to the impl's TYPE, where inherent methods live
      assert %{name: "Foo.helper", kind: :call, from: "Foo.Display.fmt"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "Foo.helper"))
    end

    test "bodyless trait method signatures are method entities under the trait" do
      %{entities: entities} = extract("trait Worker { fn run(&self); }\n", "rust")

      assert %{qualified_name: "Worker", kind: :class} = find(entities, "Worker")
      assert %{qualified_name: "Worker.run", kind: :method} = find(entities, "Worker.run")
    end

    test "turbofish calls unwrap the generic callee: free function and self method" do
      %{references: refs} =
        extract(
          """
          impl Foo {
              fn run(&self) {
                  let n = parse::<u32>();
                  self.helper::<u32>();
              }
          }
          """,
          "rust"
        )

      names = refs |> Enum.filter(&(&1.kind == :call)) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Foo.helper", "parse"]
    end

    test "generic impl blocks with differently named params share one symbol identity" do
      %{entities: entities, references: refs} =
        extract(
          """
          impl<T> Foo<T> {
              fn run(&self) { self.helper(); }
          }

          impl<U> Foo<U> {
              fn helper(&self) {}
          }
          """,
          "rust"
        )

      assert find(entities, "Foo.helper")
      assert Enum.any?(refs, &(&1.kind == :call and &1.name == "Foo.helper"))
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

    test "defimpl is scoped by its for: type: impls don't collapse onto the protocol or each other" do
      %{entities: entities, references: refs} =
        extract(
          """
          defprotocol Sized do
            def size(t)
          end

          defimpl Sized, for: BitString do
            def size(s), do: byte_size(s)
          end

          defimpl Sized, for: Map do
            def size(m), do: map_size(m)
          end
          """,
          "elixir"
        )

      assert %{qualified_name: "Sized", kind: :module} = find(entities, "Sized")

      assert %{qualified_name: "Sized.BitString", kind: :module} =
               find(entities, "Sized.BitString")

      assert %{qualified_name: "Sized.Map", kind: :module} = find(entities, "Sized.Map")

      assert %{qualified_name: "Sized.BitString.size", kind: :function} =
               find(entities, "Sized.BitString.size")

      assert %{qualified_name: "Sized.Map.size", kind: :function} =
               find(entities, "Sized.Map.size")

      assert %{name: "byte_size", kind: :call, from: "Sized.BitString.size"} =
               Enum.find(refs, &(&1.kind == :call and &1.name == "byte_size"))
    end

    test "defimpl nested directly inside a defmodule (no for:) is scoped to the enclosing module" do
      %{entities: entities} =
        extract(
          """
          defprotocol Sized do
            def size(t)
          end

          defmodule Outer do
            defimpl Sized do
              def size(_), do: 1
            end
          end
          """,
          "elixir"
        )

      assert %{qualified_name: "Sized.Outer", kind: :module} = find(entities, "Sized.Outer")

      assert %{qualified_name: "Sized.Outer.size", kind: :function} =
               find(entities, "Sized.Outer.size")

      refute Enum.any?(entities, &(&1.qualified_name == "Outer.Sized"))
    end

    test "defimpl Sized, for: [BitString, Map] fans out to one implementation per listed type" do
      %{entities: entities, references: refs} =
        extract(
          """
          defprotocol Sized do
            def size(t)
          end

          defimpl Sized, for: [BitString, Map] do
            def size(x), do: helper(x)
          end
          """,
          "elixir"
        )

      assert %{qualified_name: "Sized.BitString", kind: :module} =
               find(entities, "Sized.BitString")

      assert %{qualified_name: "Sized.Map", kind: :module} = find(entities, "Sized.Map")

      assert %{qualified_name: "Sized.BitString.size", kind: :function} =
               find(entities, "Sized.BitString.size")

      assert %{qualified_name: "Sized.Map.size", kind: :function} =
               find(entities, "Sized.Map.size")

      # The shared defimpl body is walked once per listed type, so the
      # `helper` call is attributed to BOTH generated implementations, not
      # just the first (the round-12 bug this fixes silently kept only
      # Sized.BitString and dropped Sized.Map entirely).
      assert Enum.any?(
               refs,
               &(&1.kind == :call and &1.name == "helper" and &1.from == "Sized.BitString.size")
             )

      assert Enum.any?(
               refs,
               &(&1.kind == :call and &1.name == "helper" and &1.from == "Sized.Map.size")
             )
    end

    test "macro-spliced and operator definition names are anonymous; bodies are still walked" do
      %{entities: e, references: r} =
        extract(
          """
          defmodule M do
            defmacro gen(name) do
              quote do
                def unquote(name)(x), do: helper(x)
                def unquote(:"a b#{1}")(), do: other()
                def unquote(name), do: third()
                def a <> b, do: fourth(a)
              end
            end
          end
          """,
          "elixir"
        )

      assert Enum.sort(Enum.map(e, & &1.qualified_name)) == ["M", "M.gen"]

      for name <- ["helper", "other", "third", "fourth"] do
        assert Enum.any?(r, &(&1.kind == :call and &1.name == name and &1.from == "M.gen"))
      end
    end

    test "a dot callee with a non-identifier member names nothing" do
      %{references: r} = extract("defmodule M do\n  def f, do: Mod.unquote(x)()\nend\n", "elixir")
      names = for %{kind: :call, name: n} <- r, do: n
      assert names == ["unquote"]
    end

    test "attributes named like definition or import forms are not definitions or imports" do
      %{entities: e, references: r} =
        extract("defmodule M do\n  @use true\n  @def helper()\n  @alias 1\nend\n", "elixir")

      assert Enum.map(e, & &1.qualified_name) == ["M"]
      assert [%{name: "helper", kind: :call, from: "M"}] = r
    end

    test "defimpl: for: __MODULE__ and a duplicate type resolve once; an unresolvable target is anonymous" do
      %{entities: e, references: r} =
        extract(
          """
          defmodule Outer do
            defimpl P, for: __MODULE__ do
              def f(x), do: a(x)
            end

            defimpl Q, for: [A, A] do
              def g(x), do: b(x)
            end

            defimpl R, for: unquote(t) do
              def h(x), do: c(x)
            end
          end

          defimpl S do
            def i(x), do: d(x)
          end
          """,
          "elixir"
        )

      assert Enum.sort(Enum.map(e, & &1.qualified_name)) ==
               ["Outer", "P.Outer", "P.Outer.f", "Q.A", "Q.A.g", "Outer.h", "i"]
               |> Enum.sort()

      assert Enum.any?(r, &(&1.name == "a" and &1.from == "P.Outer.f"))
      assert Enum.any?(r, &(&1.name == "c" and &1.from == "Outer.h"))
      assert Enum.any?(r, &(&1.name == "d" and &1.from == "i"))
    end

    test "qualified calls name the rightmost member, never the enclosing module" do
      %{references: r} =
        extract("defmodule M do\n  def f, do: __MODULE__.g(Other.h())\nend\n", "elixir")

      assert Enum.sort(for %{kind: :call, name: n} <- r, do: n) == ["g", "h"]
    end

    test "default argument values are dependencies of the function" do
      src = ~S"""
      defmodule M do
        def f(x \\ helper()), do: x
        def g(a, b \\ Mod.build(a)) when is_integer(a), do: b
      end
      """

      %{references: r} = extract(src, "elixir")
      calls = for %{kind: :call, name: n, from: f} <- r, do: {n, f}
      assert {"helper", "M.f"} in calls
      assert {"build", "M.g"} in calls
      # The signature and guard are not call sites.
      refute Enum.any?(calls, fn {n, _} -> n in ~w(f g is_integer) end)
    end

    test "calls inside import forms are still collected" do
      src = ~S"""
      defmodule M do
        use Foo, option: build_opts()
        import Bar, only: compute_only()
      end
      """

      %{references: r} = extract(src, "elixir")
      assert Enum.sort(for %{kind: :import, name: n} <- r, do: n) == ["Bar", "Foo"]
      calls = for %{kind: :call, name: n, from: f} <- r, do: {n, f}
      assert {"build_opts", "M"} in calls and {"compute_only", "M"} in calls
      refute Enum.any?(calls, fn {n, _} -> n in ~w(use import) end)
    end

    test "Elixir.-rooted aliases are canonical and absolute everywhere" do
      src = ~S"""
      defmodule Outer do
        defmodule Elixir.Shared do
          def s, do: :ok
        end

        alias Elixir.Some.Dep
        defimpl Elixir.P, for: [Elixir.T, T] do
          def p(_), do: :ok
        end
      end
      """

      %{entities: e, references: r} = extract(src, "elixir")
      names = e |> Enum.map(& &1.qualified_name) |> Enum.sort()
      assert names == Enum.sort(~w(Outer Shared Shared.s P.T P.T.p))
      assert for(%{kind: :import, name: n} <- r, do: n) == ["Some.Dep"]
    end
  end

  describe "review regressions" do
    test "rust: module-qualified impl type is dotted; use-list comments skipped" do
      %{entities: e, references: r} =
        extract(
          "mod m { pub struct Foo; impl Foo { pub fn helper(&self) {} } }\nimpl m::Foo<T> { fn run(&self) { self.helper(); } }\nuse std::{fs, /* c */ io};\n",
          "rust"
        )

      assert find(e, "m.Foo.run")
      refute Enum.any?(e, &String.contains?(&1.qualified_name, "::"))
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "m.Foo.helper"))

      imports = for %{kind: :import, name: n} <- r, do: n
      assert Enum.sort(imports) == ["std::fs", "std::io"]
    end

    test "go: type aliases are class entities, standalone and grouped" do
      %{entities: e} =
        extract("package p\ntype A = int\ntype (\n B = string\n C struct{}\n)\n", "go")

      assert %{kind: :class} = find(e, "A")
      assert %{kind: :class} = find(e, "B")
      assert %{kind: :class} = find(e, "C")
    end

    test "js: object-literal method drops the class receiver; nested fn in arrow is a function" do
      %{references: r} =
        extract("class C { m() { const o = { run() { this.helper(); } }; } }", "javascript")

      assert Enum.any?(r, &(&1.kind == :call and &1.name == "helper"))

      %{entities: e} =
        extract("class C { cb = () => { function local() {} } }", "javascript")

      assert %{kind: :function} = Enum.find(e, &String.ends_with?(&1.qualified_name, "local"))
    end

    test "js: named function expression is an entity; its calls are attributed to it" do
      %{entities: e, references: r} =
        extract("const cb = function recur() { recur(); };", "javascript")

      assert %{kind: :function} = find(e, "recur")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "recur" and &1.from == "recur"))
    end

    test "js: class expressions are class-like; unnamed ones drop the outer receiver" do
      src =
        "class Outer { run() { const I = class Named { helper() {} call() { this.helper(); } }; } }"

      %{entities: e, references: r} = extract(src, "javascript")
      assert %{kind: :class} = find(e, "Outer.run.Named")
      assert find(e, "Outer.run.Named.helper")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "Outer.run.Named.helper"))

      %{references: r} =
        extract(
          "class Outer { run() { const I = class { call() { this.x(); } }; } }",
          "javascript"
        )

      assert Enum.any?(r, &(&1.kind == :call and &1.name == "x"))
    end

    test "java: anonymous class body is a receiver boundary" do
      src =
        "class Outer { void make() { new Object() { void run() { this.helper(); } void helper() {} }; } void helper() {} }"

      %{entities: e, references: r} = extract(src, "java")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "helper"))
      refute Enum.any?(r, &(&1.name == "Outer.helper"))
      assert find(e, "Outer.helper")
    end

    test "rust: rooted impl paths resolve crate/self/super against the module scope" do
      src = """
      mod a { pub struct Foo; }
      mod b {
        impl crate::a::Foo { fn run(&self) { self.go(); } }
        impl self::Bar { fn x(&self) {} }
        mod c { impl super::Baz { fn y(&self) {} } }
      }
      impl m::Foo { fn z(&self) {} }
      """

      %{entities: e, references: r} = extract(src, "rust")
      assert find(e, "a.Foo.run")
      assert find(e, "b.Bar.x")
      assert find(e, "b.Baz.y")
      assert find(e, "m.Foo.z")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "a.Foo.go"))
    end

    test "js: quoted method names are normalized" do
      src = ~s|class C { "helper"() {} run() { this.helper(); } }|
      %{entities: e, references: r} = extract(src, "javascript")
      assert find(e, "C.helper")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "C.helper"))
    end

    test "ruby: scope_resolution names are dotted and share identity with nesting" do
      src = """
      module A; class B; def helper; end; end; end
      class A::B; def run; self.helper; end; end
      module X; class ::A::B; def other; end; end; end
      """

      %{entities: e, references: r} = extract(src, "ruby")
      assert find(e, "A.B.helper")
      assert find(e, "A.B.run")
      assert find(e, "A.B.other")
      refute Enum.any?(e, &String.contains?(&1.qualified_name, "::"))
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "A.B.helper"))
    end
  end

  describe "review regressions, round 2" do
    test "rust: rooted impl inside a function resolves against the module, not the fn" do
      src = "struct Foo; fn init() { impl self::Foo { fn run(&self) { self.go(); } } }"
      %{entities: e, references: r} = extract(src, "rust")
      assert find(e, "Foo.run")
      refute find(e, "init.Foo.run")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "Foo.go"))
    end

    test "rust: whitespace around :: in impl paths is trimmed" do
      src =
        "mod a { impl m :: Foo { fn run(&self) { self.helper(); } } }\nimpl crate :: a :: Bar { fn x(&self) {} }"

      %{entities: e, references: r} = extract(src, "rust")
      assert find(e, "a.m.Foo.run")
      assert find(e, "a.Bar.x")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "a.m.Foo.helper"))
      refute Enum.any?(e, &String.contains?(&1.qualified_name, " "))
    end

    test "ruby: singleton methods are qualified by receiver" do
      src =
        "def A.run; end\ndef B.run; end\nclass C; def self.go; helper; self.other; end; end\ndef A.use; self.run; end"

      %{entities: e, references: r} = extract(src, "ruby")
      assert %{kind: :method} = find(e, "A.run")
      assert %{kind: :method} = find(e, "B.run")
      assert %{kind: :method} = find(e, "C.go")
      refute find(e, "run")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "C.other"))
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "A.run" and &1.from == "A.use"))
    end

    test "python: nested def rebinding self drops the class receiver; closures keep it" do
      src = """
      class K:
          def m(self):
              def inner(self):
                  return self.helper()
              def closure():
                  return self.other()
      """

      %{references: r} = extract(src, "python")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "helper"))
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "K.other"))
    end

    test "ruby: interpolated require is a plain call, literal require an import" do
      src = ~S|require "adapters/#{backend}/driver"| <> "\nrequire \"json\"\n"
      %{references: r} = extract(src, "ruby")
      assert [%{name: "json"}] = Enum.filter(r, &(&1.kind == :import))
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "require"))
    end
  end

  describe "review regressions, round 3" do
    test "ruby: named receiver inside its own class matches def self.other" do
      src = "class C; def C.run; self.other; end; def self.other; end; end"
      %{entities: e, references: r} = extract(src, "ruby")
      assert find(e, "C.run")
      assert find(e, "C.other")
      refute find(e, "C.C.run")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "C.other"))
    end

    test "typescript: namespaces qualify their members" do
      src =
        "namespace A { export function run() { go(); } }\nnamespace B { export function run() {} }"

      %{entities: e, references: r} = extract(src, "typescript")
      assert find(e, "A.run")
      assert find(e, "B.run")
      refute find(e, "run")
      assert Enum.any?(r, &(&1.name == "go" and &1.from == "A.run"))
    end

    test "python: lambda binding self shadows the receiver in its body only" do
      src = """
      class K:
          def m(self):
              a = lambda self: self.helper()
              b = lambda: self.helper()
              c = lambda x=self.dflt(): x
      """

      %{references: r} = extract(src, "python")
      calls = for %{kind: :call, name: n} <- r, do: n
      assert Enum.sort(calls) == ["K.dflt", "K.helper", "helper"]
    end

    test "ruby: singleton method on a local variable drops the class receiver" do
      src = "class C; def attach(other); def other.run; self.helper(); end; end; end"
      %{entities: e, references: r} = extract(src, "ruby")
      assert find(e, "C.attach.run")
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "helper"))
      refute Enum.any?(r, &(&1.name == "C.helper"))
    end

    test "ruby: receiver-qualified require is a call, bare/Kernel require an import" do
      src = ~S|validator.require("token")| <> "\nrequire \"json\"\nKernel.require \"set\"\n"
      %{references: r} = extract(src, "ruby")
      imports = for %{kind: :import, name: n} <- r, do: n
      assert Enum.sort(imports) == ["json", "set"]
      assert Enum.any?(r, &(&1.kind == :call and &1.name == "require"))
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

    test "python: a rejected nested class keeps the outer receiver only in its body" do
      long = String.duplicate("X", 300)

      src = """
      class Factory:
          def build(self):
              class #{long}:
                  value = self.helper()

                  def run(self):
                      return self.helper()
      """

      %{references: refs} = extract(src, "python")
      calls = for %{kind: :call, name: n, from: f} <- refs, do: {n, f}
      # The class body captures build's `self` (Factory); `run`'s own `self` is
      # an instance of the nameless class, so it stays unresolved (bare).
      assert {"Factory.helper", "Factory.build"} in calls
      assert {"helper", "Factory.build.run"} in calls
    end

    test "ruby: a rejected nested class or module clears the enclosing receiver" do
      long = "M" <> String.duplicate("x", 300)

      for kw <- ["module", "class"] do
        src = "class C\n  #{kw} #{long}\n    self.helper\n  end\n  def self.helper; end\nend\n"
        %{references: refs} = extract(src, "ruby")
        # `self` in the nested body is that module/class, which has no identity.
        refute Enum.any?(refs, &(&1.name == "C.helper"))
        assert Enum.any?(refs, &(&1.name == "helper" and &1.from == "C"))
      end
    end

    test "an oversized definition is anonymous: calls inside get the outer from" do
      long = String.duplicate("x", 300)
      src = "class K:\n    def #{long}(self):\n        helper()\n"
      %{references: refs} = extract(src, "python")
      # The invariant check in extract/2 also asserts every `from` is emitted.
      assert [%{name: "helper", from: "K"}] = refs
    end

    test "ruby: an oversized singleton-method name keeps its explicit receiver binding" do
      long = String.duplicate("x", 300)

      src =
        "class C; class A; end; def A.#{long}; self.helper(); end; def C.#{long}; self.other(); end; end"

      %{entities: e, references: refs} = extract(src, "ruby")
      assert Enum.sort(Enum.map(e, & &1.qualified_name)) == ["C", "C.A"]
      assert Enum.any?(refs, &(&1.name == "C.A.helper" and &1.from == "C"))
      assert Enum.any?(refs, &(&1.name == "C.other" and &1.from == "C"))
    end

    test "ruby: an oversized singleton receiver is unresolvable, so self is too" do
      long = String.duplicate("X", 300)
      src = "class C; def #{long}.run; self.helper(); end; end"
      %{references: refs} = extract(src, "ruby")
      assert [%{name: "helper", from: "C"}] = refs
    end
  end

  describe "review regressions, round 4" do
    test "go: interface method elements are methods of the interface" do
      %{entities: e} = extract("package p\ntype Worker interface { Run() }", "go")
      assert %{kind: :method} = find(e, "Worker.Run")
    end

    test "python: a self-rebinding nested def evaluates defaults in the outer scope" do
      src = """
      class K:
          def m(self):
              def inner(self=self.helper()):
                  return self.other()
      """

      %{references: r} = extract(src, "python")
      assert Enum.any?(r, &(&1.name == "K.helper" and &1.from == "K.m"))
      assert Enum.any?(r, &(&1.name == "other" and &1.from == "K.m.inner"))
    end
  end

  describe "review regressions, round 5" do
    defp call_names(src, lang) do
      %{references: r} = extract(src, lang)
      for %{kind: :call} = c <- r, do: {c.name, c.from}
    end

    test "java: enum constant body is an anonymous receiver boundary" do
      src =
        "enum Op { PLUS { int apply() { return this.helper(); } int helper() { return 1; } }; int helper() { return 0; } }"

      assert {"helper", _} = List.keyfind(call_names(src, "java"), "helper", 0)
    end

    test "ruby: nested def defines a method on the containing class" do
      src = "class C; def install; def helper; end; end; def run; self.helper(); end; end"
      %{entities: e} = extract(src, "ruby")
      assert %{kind: :method} = find(e, "C.helper")
      refute find(e, "C.install.helper")
      assert {"C.helper", "C.run"} in call_names(src, "ruby")
    end

    test "python: class bases and defaults evaluate in the enclosing scope" do
      src = """
      class Factory:
          def build(self):
              class Product(self.base()):
                  pass

              def inner(value=self.base()):
                  pass
      """

      assert call_names(src, "python") == [
               {"Factory.base", "Factory.build"},
               {"Factory.base", "Factory.build"}
             ]
    end

    test "rust: parenthesized callees are unwrapped" do
      assert call_names("fn main() { (helper)(); }", "rust") == [{"helper", "main"}]
      assert [{"helper", "main"}] = call_names("fn main() { (module::helper)(); }", "rust")
    end

    test "python/js/ts: parenthesized callees are unwrapped" do
      assert [{"helper", "f"}] = call_names("def f():\n    (helper)()\n", "python")

      py = "class K:\n    def m(self):\n        (self.helper)()\n"
      assert call_names(py, "python") == [{"K.helper", "K.m"}]

      for lang <- ["javascript", "typescript"] do
        assert [{"helper", "f"}] = call_names("function f() { (helper)(); }", lang)
        src = "class C { m() { (this.helper)(); } }"
        assert call_names(src, lang) == [{"C.helper", "C.m"}]
      end
    end
  end

  describe "review regressions, round 6" do
    test "python: a class body keeps the outer receiver; its methods bind the class" do
      src = """
      class Factory:
          def build(self):
              class Product:
                  value = self.helper()

                  def run(self):
                      self.go()
      """

      assert call_names(src, "python") == [
               {"Factory.helper", "Factory.build.Product"},
               {"Factory.build.Product.go", "Factory.build.Product.run"}
             ]

      assert [{"K.x", "K.m"}] =
               call_names("class K:\n    def m(self):\n        self.x()\n", "python")
    end

    test "js/ts: class heritage evaluates in the enclosing scope" do
      src = "class Outer { make() { class Inner extends this.base() { run() { this.go(); } } } }"

      for lang <- ["javascript", "typescript"] do
        assert call_names(src, lang) == [
                 {"Outer.base", "Outer.make"},
                 {"Outer.make.Inner.go", "Outer.make.Inner.run"}
               ]
      end
    end

    test "go: parenthesized callees are unwrapped" do
      assert call_names("package p\nfunc main() { (helper)() }", "go") == [{"helper", "main"}]

      plain = call_names("package p\nfunc main() { pkg.Helper() }", "go")
      assert call_names("package p\nfunc main() { (pkg.Helper)() }", "go") == plain
    end
  end

  describe "review regressions, round 7" do
    defp calls(src, lang) do
      %{references: r} = extract(src, lang)
      for %{kind: :call} = c <- r, do: {c.name, c.from}
    end

    defp ents(src, lang) do
      %{entities: e} = extract(src, lang)
      for x <- e, do: {x.qualified_name, x.kind}
    end

    test "python: a nested method without a self parameter keeps the captured receiver" do
      src = """
      class Factory:
          def build(self):
              class Product:
                  @staticmethod
                  def run():
                      return self.helper()

                  @classmethod
                  def make(cls):
                      return self.other()

                  def own(self):
                      return self.mine()
      """

      assert calls(src, "python") == [
               {"Factory.helper", "Factory.build.Product.run"},
               {"Factory.other", "Factory.build.Product.make"},
               {"Factory.build.Product.mine", "Factory.build.Product.own"}
             ]

      assert [{"K.x", "K.m"}] = calls("class K:\n    def m(self):\n        self.x()\n", "python")
    end

    test "ruby: class << other clears the receiver; class << self keeps it" do
      src =
        "class C; def attach(other); class << other; def run; self.helper(); end; end; end; end"

      assert calls(src, "ruby") == [{"helper", "C.attach.run"}]

      src = "class C; class << self; def run; self.helper(); end; end; end"
      assert calls(src, "ruby") == [{"C.helper", "C.run"}]

      src = "class C; class << Foo; def run; self.helper(); end; end; end"
      assert calls(src, "ruby") == [{"C.Foo.helper", "C.Foo.run"}]
    end

    test "ruby: a def nested in an explicit-receiver method defines a method on the class" do
      src = "class C; def C.install; def helper; end; end; end"
      assert {"C.helper", :method} in ents(src, "ruby")
    end

    test "rust: non-path callee expressions are not named" do
      src = "fn factory() -> impl Fn() { || {} } fn run() { factory()(); }"
      assert calls(src, "rust") == [{"factory", "run"}]
    end

    test "python/js: non-identifier callee expressions are not named" do
      assert calls("def run():\n    factory()()\n", "python") == [{"factory", "run"}]

      src = "function run() { (function() { go(); })(); }"

      for lang <- ["javascript", "typescript"] do
        assert calls(src, lang) == [{"go", "run"}]
      end
    end
  end

  describe "review regressions, round 8" do
    test "ruby: class << ::A is rooted; class << A::B still nests" do
      src = "class C; class << ::A; def run; self.helper; end; end; end"
      assert calls(src, "ruby") == [{"A.helper", "A.run"}]

      src = "class C; class << A::B; def run; self.helper; end; end; end"
      assert calls(src, "ruby") == [{"C.A.B.helper", "C.A.B.run"}]
    end

    test "js/ts: computed class member keys run in the enclosing instance" do
      src = "class Outer { make() { class Inner { [this.key()]() {} } } }"

      for lang <- ["javascript", "typescript"] do
        assert calls(src, lang) == [
                 {"Outer.key", "Outer.make"}
               ]
      end
    end

    test "ruby: the superclass expression runs in the enclosing scope" do
      src = "class Outer; class Inner < self.base(); end; end"
      assert calls(src, "ruby") == [{"Outer.base", "Outer"}]
    end

    test "rust: scoped callees resolve through the name field" do
      for src <- ["util::helper()", "util :: helper()", "util:: /* c */ helper()"] do
        assert calls("fn run() { #{src}; }", "rust") == [{"helper", "run"}]
      end
    end
  end

  describe "invariants" do
    # Each generator ({head, member template with `@@` = index, tail}) emits
    # ~10_050 definitions in that language's most common nesting (methods in a
    # class/impl). Whatever path a language's walk takes, output must stop
    # exactly at the 10_000-item cap.
    @over_cap 10_050
    @generators %{
      "python" => {"class K:\n", "    def m@@(self): pass\n", ""},
      "javascript" => {"class C {\n", "  m@@() {}\n", "}\n"},
      "typescript" => {"class C {\n", "  m@@(): void {}\n", "}\n"},
      "go" => {"package p\ntype T struct{}\n", "func (t T) M@@() {}\n", ""},
      "rust" => {"struct S;\nimpl S {\n", "  fn m@@(&self) {}\n", "}\n"},
      "ruby" => {"class C\n", "  def m@@; end\n", "end\n"},
      "java" => {"class C {\n", "  void m@@() {}\n", "}\n"},
      "elixir" => {"defmodule M do\n", "  def f@@, do: :ok\n", "end\n"}
    }

    for {language, {head, member, tail}} <- @generators do
      @language language
      @head head
      @member member
      @tail tail
      test "#{language}: output never exceeds the 10_000-item cap" do
        body = Enum.map_join(1..@over_cap, &String.replace(@member, "@@", to_string(&1)))
        src = @head <> body <> @tail
        %{entities: e, references: r} = extract(src, @language)
        assert length(e) + length(r) == 10_000
      end
    end

    test "js/ts: an object-literal method's computed key runs in the enclosing scope" do
      src = "class Outer { make() { return { [this.key()]() { go(); } }; } }"

      for lang <- ["javascript", "typescript"] do
        %{references: r} = extract(src, lang)
        assert Enum.any?(r, &(&1.name == "Outer.key" and &1.from == "Outer.make"))
        refute Enum.any?(r, &(&1.name == "key"))
      end
    end
  end

  describe "member names and impl types without a static identity" do
    test "js/ts: parser identifiers keep Unicode names and their receiver" do
      for lang <- ["javascript", "typescript"] do
        src = "class Café { método() { this.otro(); } otro() {} }"
        %{entities: e, references: r} = extract(src, lang)
        assert find(e, "Café") && find(e, "Café.método") && find(e, "Café.otro")
        assert Enum.any?(r, &(&1.name == "Café.otro" and &1.from == "Café.método"))
      end
    end

    test "js/ts: literal keys use the full ECMAScript identifier sets" do
      for lang <- ["javascript", "typescript"] do
        %{entities: e} = extract(~s|class C { "℘"() {} ["a·b"]() {} "x‍y"() {} }|, lang)
        assert find(e, "C.℘") && find(e, "C.a·b") && find(e, "C.x‍y")
      end
    end

    test "js/ts: literal keys are validated on their decoded value" do
      for lang <- ["javascript", "typescript"] do
        src = ~S|class C { ["helper"]() {} ["'quoted'"]() {} "\u{1F600}"() {} "\uD83D"() {} }|
        %{entities: e} = extract(src, lang)
        # Escapes decode to `helper`; a key whose value contains quotes, a
        # non-identifier character or a lone surrogate names no entity.
        assert find(e, "C.helper")
        assert e |> Enum.map(& &1.qualified_name) |> Enum.sort() == ["C", "C.helper"]
      end
    end

    test "js/ts: escaped identifiers canonicalize alike in definitions and callees" do
      for lang <- ["javascript", "typescript"] do
        src = ~S"""
        class C {
          "helper"() {}
          run() { this.helper(); this.h\u{65}lper(); }
        }
        """

        %{entities: e, references: r} = extract(src, lang)
        assert find(e, "C.helper") && find(e, "C.run")
        calls = for %{kind: :call} = ref <- r, do: {ref.name, ref.from}
        assert calls == [{"C.helper", "C.run"}, {"C.helper", "C.run"}]
      end
    end

    test "js/ts: imports canonicalize escapes like definitions and callees" do
      for lang <- ["javascript", "typescript"] do
        src = ~S"""
        import d\u0065f, { h\u0065lper, "x" as y, "a b" as z } from "p\u006bg";
        import "./rel/m\u006fd";
        """

        %{references: r} = extract(src, lang)
        imports = for %{kind: :import, name: name} <- r, do: name
        assert Enum.sort(imports) == Enum.sort(["pkg", "def", "helper", "x", "./rel/mod"])
      end
    end

    test "js/ts: a line continuation between surrogate escapes still pairs them" do
      for lang <- ["javascript", "typescript"] do
        # `\uD835\` + newline + `\uDC9C` is the single identifier character U+1D49C.
        src = "class C { \"\\uD835\\\n\\uDC9C\"() {} \"\\uD835x\\uDC9C\"() {} }"
        %{entities: e} = extract(src, lang)
        assert e |> Enum.map(& &1.qualified_name) |> Enum.sort() == ["C", "C.\u{1D49C}"]
      end
    end

    test "js/ts: decoded NULs and out-of-range escapes never become names" do
      for lang <- ["javascript", "typescript"] do
        src = ~S"""
        import "pkg\x00";
        import "ok";
        class C { "a\u{110000}\uDC00"() {} "\u{10000}"() {} }
        """

        %{entities: e, references: r} = extract(src, lang)
        assert for(%{kind: :import, name: n} <- r, do: n) == ["ok"]
        # The out-of-range escape is rejected, not turned into a valid U+10000.
        refute find(e, "C.a\u{10000}")
      end

      src = ~S|declare module "m\0x" { import "ok"; export function f() { g(); } }|
      %{entities: e, references: r} = extract(src, "typescript")
      refute Enum.any?(e, &String.contains?(&1.qualified_name, <<0>>))
      # The unstorable module is anonymous: nothing inside points `from` it.
      assert find(e, "f")
      assert Enum.any?(r, &(&1.name == "ok" and is_nil(&1.from)))
      assert Enum.any?(r, &(&1.name == "g" and &1.from == "f"))
    end

    test "javascript: legacy octal escapes decode with ECMAScript digit limits" do
      src = ~S"""
      const o = { "f\157o"() {}, "\101b"() {}, "a\477b"() {}, "\8x"() {} };
      """

      # \157 -> o, \101 -> A, \477 -> ' + "7" (quote: no entity), \8 -> 8.
      %{entities: e} = extract(src, "javascript")
      assert e |> Enum.map(& &1.qualified_name) |> Enum.sort() == ["Ab", "foo"]
    end

    test "js/ts: comments inside a computed string key don't drop the member" do
      for lang <- ["javascript", "typescript"] do
        %{entities: e} = extract(~s|class C { ["helper" /* why */]() {} }|, lang)
        assert find(e, "C.helper")
      end
    end

    test "typescript: dotted namespaces and string modules keep their scope" do
      src = """
      namespace A.B { export function run() {} }
      namespace C.D { export function run() {} }
      declare module "pkg-a" { export function g(): void {} }
      declare module "@scope/pkg" { export function g(): void {} }
      """

      %{entities: e} = extract(src, "typescript")

      for name <- ~w(A.B.run C.D.run pkg-a pkg-a.g @scope/pkg @scope/pkg.g),
          do: assert(find(e, name), "missing #{name}")
    end

    test "js/ts: #private methods are entities matching their this.#x callees" do
      for lang <- ["javascript", "typescript"] do
        %{entities: e, references: r} =
          extract("class C { #helper() {} run() { this.#helper(); } }", lang)

        assert %{kind: :method} = find(e, "C.#helper")
        assert Enum.any?(r, &(&1.name == "C.#helper" and &1.from == "C.run"))
      end
    end

    test "js/ts: only identifier-like member keys become entities" do
      for lang <- ["javascript", "typescript"] do
        src = """
        class C {
          plain() {}
          ["helper"]() {}
          [this.key()]() { this.plain(); }
          ['a b']() {}
          "q c"() {}
          "ok"() {}
          [Symbol.iterator]() {}
        }
        """

        assert ents(src, lang) == [
                 {"C", :class},
                 {"C.plain", :method},
                 {"C.helper", :method},
                 {"C.ok", :method}
               ]

        # Anonymous members still walk their bodies with the class receiver and
        # the enclosing named definition as `from`.
        assert calls(src, lang) == [{"key", nil}, {"C.plain", "C"}]
      end
    end

    test "js/ts: anonymous object-literal member rebinds this" do
      src = "class C { m() { return { [k()]() { this.x(); } }; } }"

      for lang <- ["javascript", "typescript"] do
        assert calls(src, lang) == [{"k", "C.m"}, {"x", "C.m"}]
      end
    end

    test "rust: impl type identity is its path type" do
      cases = [
        {"impl Foo for &Bar { fn a(&self) { self.b(); } }", ["Bar.Foo", "Bar.Foo.a"], "Bar.b"},
        {"impl Foo for &mut Bar { fn a(&self) { self.b(); } }", ["Bar.Foo", "Bar.Foo.a"],
         "Bar.b"},
        {"impl<'a, T> Foo for &'a T { fn a(&self) { self.b(); } }", ["T.Foo", "T.Foo.a"], "T.b"},
        {"impl Foo for (A, B) { fn a(&self) { self.b(); } }", ["Foo", "Foo.a"], "Foo.b"},
        {"impl Foo for [u8] { fn a(&self) { self.b(); } }", ["Foo", "Foo.a"], "Foo.b"},
        {"impl Foo for [u8; 4] { fn a(&self) { self.b(); } }", ["Foo", "Foo.a"], "Foo.b"},
        {"impl Foo for fn(u8) -> u8 { fn a(&self) { self.b(); } }", ["Foo", "Foo.a"], "Foo.b"},
        {"impl Foo for *const Bar { fn a(&self) { self.b(); } }", ["Bar.Foo", "Bar.Foo.a"],
         "Bar.b"}
      ]

      for {src, names, callee} <- cases do
        assert Enum.map(ents(src, "rust"), &elem(&1, 0)) == names, src
        assert [{^callee, _}] = calls(src, "rust"), src
      end
    end

    test "rust: an inherent impl on a non-path type has no impl scope segment" do
      assert ents("impl (A, B) { fn a(&self) {} }", "rust") == [{"a", :method}]
    end
  end

  defp find(entities, qualified_name),
    do: Enum.find(entities, &(&1.qualified_name == qualified_name))
end
