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

  defp find(entities, qualified_name),
    do: Enum.find(entities, &(&1.qualified_name == qualified_name))
end
