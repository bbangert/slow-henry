defmodule RetrievalNode.Graph.Extractor.TreeSitter do
  @moduledoc """
  Tree-sitter-backed `RetrievalNode.Graph.Extractor` impl.

  `input` is `{root_node, source}` — an ALREADY-PARSED tree-sitter root. This
  module never calls `parser_parse`; the parse belongs to
  `RetrievalNode.Chunking.TreeSitterImpl` (one parse, two consumers: chunk
  boundaries and graph extraction both walk the same tree).

  Unlike chunking's boundary-only walk (which only descends until it finds a
  chunk-boundary kind, then treats that subtree as opaque chunk text), this is
  a full-tree walk: every named node is visited, including deep inside
  function bodies, because calls and imports live there. The per-node context
  threaded down the walk (scope, enclosing definition, receiver, ...) is
  `RetrievalNode.Graph.Extractor.TreeSitter.WalkState`; its moduledoc defines
  every field. Because `extract/3` walks exactly one already-parsed file's root
  node per call, every reference's `from` can only ever name a definition from
  THIS file.

  Defensive cap: at most `@max_items` combined entities+references are
  collected per file; a generated/minified file could otherwise produce
  millions of rows downstream. Collection (and further descent into the
  subtree that would exceed it) stops once the cap is hit.

  ## Extraction rules

  Every change to this module must follow these rules.

  ### Naming

    * A `qualified_name` is the enclosing scope's segments plus the definition's
      own name, joined with ".". Segments come from AST name fields, not from
      splitting arbitrary source text.
    * Language path separators (`::`, Ruby `A::B`, Rust `a::B`) are normalized
      to ".".
    * Type arguments are not part of identity: `Foo<T>` is `Foo` (Rust impl
      types and trait names, Go generic receivers).
    * Quoted member names are unquoted (`"helper"() {}` is `helper`).
    * Output names never contain `::`, whitespace, quotes, backticks,
      parentheses or `..`, and never start or end with ".". Import references
      are module/path strings and are exempt from the `::`/`..`/dot rules. The
      test helper asserts all of this on every result.
    * JS/TS names the parser recognises as identifiers are taken as-is:
      Unicode identifiers, `#private` names (kept with their `#`, matching the
      `this.#x` callee) and `namespace A.B`. Only LITERAL member keys are
      validated: a string literal (also inside `[...]`, comments ignored) names
      the member when its DECODED value (escapes resolved, never quote-trimmed
      source text) is an ECMAScript IdentifierName, including the Other_ID_*
      code points. Any other
      key (`[expr]`, `"a b"`, numbers) makes an anonymous function-like
      container: no entity, body still walked. A TS ambient module is named by
      its path string (`"pkg-a"`, `"@scope/pkg"`) when that satisfies the
      output naming rules.
    * JS/TS identifiers are canonical: `\\u` escapes inside an identifier are
      decoded the same way EVERYWHERE a name is emitted: definitions, callees,
      and import specifiers/default imports (`h\\u0065lper` is `helper` in
      all three). String values (literal keys, module names, import sources)
      decode every escape, including legacy octal (`\\157` is `o`) with
      ECMAScript's digit-length limits; an undecodable or non-hygienic import
      source is omitted.
    * A Rust impl's type identity is its path type: references and pointers
      unwrap to the pointee, generics to their base. A type without one (tuple,
      array, slice, fn pointer, ...) makes the trait the container
      (`impl X for (A, B)` names `X`); an inherent impl on such a type adds no
      scope segment.
    * Elixir: module aliases are one dotted token (`Foo.Bar`), nested modules
      join their enclosing scope like any definition. Aliases are canonical
      wherever they name something (modules, protocols, `defimpl` targets,
      imports): `Elixir.Foo` is the absolute `Foo`, rooted like Ruby `::A`. A function is named by
      its head's identifier (also under a `when` guard). A module or function
      name that is not static (`def unquote(name)()`, `defmodule unquote(m)`,
      operator heads, quoted atoms) makes the definition anonymous. `defimpl P,
      for: T` is the module `P.T`, ABSOLUTE (never nested in the module it is
      written in); `for: [A, B]` is one module per type (`P.A`, `P.B`), each
      walking the body; `for: __MODULE__` or no `for:` inside a named module
      targets that module. A `defimpl` with no resolvable target is anonymous.
    * Remaining source-text splitting is confined to nodes whose text is
      already a path (Ruby `constant`/`scope_resolution`, Rust path types and
      impl paths, callee fallback), where `::`/`.` are the only separators.

  ### Evaluation scope

  A definition's header is evaluated in the ENCLOSING scope (the outer
  receiver and `from`); only its body sees the new scope.

    * Python parameter defaults, annotations and class bases.
    * JS/TS class heritage (`extends <expr>`) and computed member keys, for
      class members and object-literal methods alike.
    * Ruby superclass expressions, and the `expr` of `class << expr`.
    * Elixir has no separate header scope: a `def` head (name, parameters,
      `when` guards) parses as calls but is not a call site, so only the body
      (`do` block or `do:` value) and default values (the right side of
      `arg \\\\ default`, evaluated when the function is called) are walked.

  ### Receiver binding

  The receiver is what `self`/`this` calls qualify to (`WalkState.receiver`).
  An unresolved receiver leaves the callee bare; never guess.
  A class or module with no emitted name (unnamed, or its name rejected as
  oversized/unstorable) has no identity for `self` to resolve to, so it is a
  receiver boundary in every language, except a Python class BODY, which
  never binds `self` (its `self`-taking methods stay unresolved instead).

    * Python: a method binds its class only if it takes `self`. A class body
      keeps the outer receiver. A nested def or lambda that takes `self`
      shadows the outer one.
    * JS/TS: ordinary functions (declarations, expressions, generators) and
      object-literal methods rebind `this`, so it is unresolved inside them.
      Arrow functions inherit it. Anonymous classes are boundaries.
    * Java: anonymous class bodies (`new T() { ... }`, enum constant bodies)
      are boundaries.
    * Rust: `self` calls in `impl Trait for T` target `T`, where the inherent
      members live, while definitions are scoped `T.Trait`. A rooted impl type
      path (`crate::`, `self::`, `super::`) resolves against the enclosing
      MODULE path only, never function or impl names.
    * Elixir: there is no `self`/`this`; a module is a receiver only for
      `defimpl` target resolution. `Mod.fun()` and `__MODULE__.fun()` name
      `fun`, never qualified.
    * Ruby: `def self.x` binds the class. `def A.x` binds `A` (not re-prefixed
      when already inside `A`), even when the method's own name is rejected; an
      unemittable receiver is unresolvable. Singleton methods and singleton
      classes on an unresolvable receiver clear it. A nested `def` defines on
      the containing class, not on the enclosing method.

  ### Callees

  Only identifier, path and member callees are named, after unwrapping
  grouping parentheses and Rust generic/turbofish wrappers. Any other callee
  expression emits no reference, but the calls nested inside it are still
  collected.

  Elixir: `f(x)` names `f`, `Mod.f(x)` names `f` (a `dot` whose member is not an
  identifier names nothing). The right operand of `|>` is always a call, so a
  bare `x |> helper` names `helper`; other bare identifiers are variables. `@attr value` and `@attr` are not calls, calls in
  the value are; typespec attributes (`@spec`, `@type`, ...) are skipped
  entirely. `alias`/`import`/`use`/`require` emit one import reference: the
  first argument's module alias (`alias Foo.{A, B}` is `Foo`); calls in their
  other arguments or block (`use Foo, opts: build()`) are still collected. The
  grammar cannot tell `map.field` from a no-parens call, so it is a call to
  `field`.

  ### Limits

  The item cap, the symbol-size limit and storability (no control characters,
  e.g. a decoded NUL) are enforced only in `add_entity/2` and
  `add_reference/2`, the single emission choke point. The walkers' `at_cap?/1`
  checks are early exits, never the enforcement. A definition whose name would
  be rejected there is treated as anonymous, so it never becomes scope, `from`
  or receiver: every reference's `from` names an emitted entity.

  ### Change discipline

  A fix states the rule it implements and checks the same construct in every
  language this module handles.
  """

  @behaviour RetrievalNode.Graph.Extractor

  alias RetrievalNode.Graph.Extractor.TreeSitter.WalkState
  alias TreeSitterLanguagePack, as: TS

  @max_items 10_000

  # No real code symbol approaches this length; an oversized "name" is
  # minified/generated code the grammar mislabels as an identifier. Beyond
  # junk quality, these are lethal downstream: entities' composite unique
  # btree index rejects rows past ~2,700 bytes (Postgres index-row limit),
  # which would discard the whole `Ingest.FileIngest.apply/2` write. Skipped,
  # not truncated — truncation would collide unrelated junk under one entity.
  @max_symbol_bytes 256

  # Node kind -> definition category, per language. Anything not listed here
  # is not a definition node. Category feeds `entity_kind_for/2`:
  #   :class_like  -> :class
  #   :module_like -> :module
  #   :function_like -> :function, UNLESS the immediately-enclosing container
  #                      is :class_like -> :method
  #   :method_like -> :method, always -- used only for go's method_declaration
  #                    (see the dedicated handle_definition/7 clause below):
  #                    a go method is never nested inside its receiver type's
  #                    AST node, so the :function_like container-based rule
  #                    above can't fire for it the way it does for every
  #                    other language's methods.
  @definition_kinds %{
    "python" => %{
      "function_definition" => :function_like,
      "class_definition" => :class_like
    },
    "javascript" => %{
      "function_declaration" => :function_like,
      "generator_function_declaration" => :function_like,
      "method_definition" => :function_like,
      "function_expression" => :function_like,
      "generator_function" => :function_like,
      "class_declaration" => :class_like,
      "class" => :class_like
    },
    "typescript" => %{
      "function_declaration" => :function_like,
      "generator_function_declaration" => :function_like,
      "method_definition" => :function_like,
      # Interface members (`interface Shape { area(): number }`) parse as
      # their own node kind, distinct from `method_definition` (a concrete
      # class body method) -- `method_signature` has a "name" field and,
      # nested directly inside `interface_declaration` (already :class_like
      # above), comes out :method via the usual
      # function-nested-in-class-like rule. `abstract_method_signature`
      # (an abstract class's unimplemented member, e.g. `abstract area():
      # number;`) is added alongside it for the same reason, though its
      # enclosing node kind is `abstract_class_declaration`, which this table
      # does not list as :class_like -- an abstract method therefore still
      # surfaces as a bare, unscoped :function rather than `<Class>.<method>`
      # until that container is tracked too; deliberately out of scope here.
      "method_signature" => :function_like,
      "abstract_method_signature" => :function_like,
      "function_expression" => :function_like,
      "generator_function" => :function_like,
      "class_declaration" => :class_like,
      "class" => :class_like,
      "interface_declaration" => :class_like,
      "type_alias_declaration" => :class_like,
      "enum_declaration" => :class_like,
      "internal_module" => :module_like,
      "module" => :module_like
    },
    "go" => %{
      "function_declaration" => :function_like,
      "method_declaration" => :function_like,
      # Interface members (`type W interface { Run() }`) inherit the type's scope.
      "method_elem" => :function_like,
      "type_declaration" => :class_like
    },
    "rust" => %{
      "function_item" => :function_like,
      "function_signature_item" => :function_like,
      "struct_item" => :class_like,
      "enum_item" => :class_like,
      "trait_item" => :class_like,
      "impl_item" => :class_like,
      "mod_item" => :module_like
    },
    "ruby" => %{
      "method" => :function_like,
      "singleton_method" => :function_like,
      "class" => :class_like,
      "module" => :module_like
    },
    "java" => %{
      "method_declaration" => :function_like,
      "constructor_declaration" => :function_like,
      "class_declaration" => :class_like,
      "interface_declaration" => :class_like,
      "enum_declaration" => :class_like,
      "record_declaration" => :class_like
    }
  }

  @call_kinds %{
    "python" => "call",
    "javascript" => "call_expression",
    "typescript" => "call_expression",
    "go" => "call_expression",
    "rust" => "call_expression",
    "ruby" => "call",
    "java" => "method_invocation"
  }

  @import_kinds %{
    "python" => ~w(import_statement import_from_statement),
    "javascript" => ~w(import_statement),
    "typescript" => ~w(import_statement),
    "go" => ~w(import_declaration),
    "rust" => ~w(use_declaration),
    "ruby" => [],
    "java" => ~w(import_declaration)
  }

  # Elixir parses every construct as a `call` node discriminated by its target
  # identifier, which a kind-keyed table can't express, so it has its own
  # process_child/6 clause instead of entries in the tables above.
  # defmodule/defprotocol/defimpl are :module_like; the def-family is
  # :function_like (a function directly inside a module is a :function).
  @elixir_module_forms ~w(defmodule defprotocol defimpl)
  @elixir_function_forms ~w(def defp defmacro defmacrop defguard defguardp)
  @elixir_def_forms @elixir_module_forms ++ @elixir_function_forms
  @elixir_import_forms ~w(alias import use require)

  # Typespec attributes are the type language, not runtime code: `@spec f(a) ::
  # b` writes `f` in call syntax but is a signature. They are never descended
  # into, unlike other attribute values (`@x String.trim(y)` has a real call).
  @elixir_typespec_attrs ~w(spec callback macrocallback type typep opaque)

  # `def unquote(name)()` and friends: macro splices have no static name.
  @elixir_splice_forms ~w(unquote unquote_splicing)

  @impl true
  def extract({root, source}, language, _opts) do
    def_kinds = Map.get(@definition_kinds, language, %{})
    call_kind = Map.get(@call_kinds, language)
    import_kinds = Map.get(@import_kinds, language, [])
    lang_ctx = %{def_kinds: def_kinds, call_kind: call_kind, import_kinds: import_kinds}

    state = %WalkState{}

    acc = %{entities: [], references: [], count: 0}

    acc = walk(root, source, language, lang_ctx, state, acc)

    {:ok, %{entities: Enum.reverse(acc.entities), references: Enum.reverse(acc.references)}}
  end

  defp walk(node, source, language, lang_ctx, state, acc) do
    walk_nodes(named_children(node), source, language, lang_ctx, state, acc)
  end

  # Like walk/6, but over an explicit node list instead of a parent's named
  # children.
  defp walk_nodes(nodes, source, language, lang_ctx, state, acc) do
    Enum.reduce_while(nodes, acc, fn node, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont, process_child(node, source, language, lang_ctx, state, acc)}
      end
    end)
  end

  defp process_child(child, source, "elixir" = language, lang_ctx, state, acc) do
    cond do
      TS.node_kind(child) == "call" ->
        handle_elixir_call(child, source, language, lang_ctx, state, acc)

      bare_pipe_callee(child, source) ->
        # `x |> helper` calls helper/1: the right operand of `|>` is always a
        # call, but without parens the grammar makes it a bare identifier.
        # The reference's line is the callee's (the operator node starts at the
        # pipeline's input, possibly lines earlier).
        callee = bare_pipe_callee(child, source)
        left = List.wrap(TS.node_child_by_field_name(child, "left"))
        acc = walk_nodes(left, source, language, lang_ctx, state, acc)

        add_reference(acc, %{
          name: callee,
          kind: :call,
          from: state.enclosing_qname,
          line: line(TS.node_child_by_field_name(child, "right"))
        })

      true ->
        walk(child, source, language, lang_ctx, state, acc)
    end
  end

  defp process_child(child, source, language, lang_ctx, state, acc) do
    kind = TS.node_kind(child)

    cond do
      Map.has_key?(lang_ctx.def_kinds, kind) ->
        handle_definition(child, kind, source, language, lang_ctx, state, acc)

      kind == lang_ctx.call_kind ->
        handle_call(child, source, language, state, acc)
        |> maybe_walk(child, source, language, lang_ctx, state)

      kind in lang_ctx.import_kinds ->
        handle_import(child, source, language, state, acc)

      anonymous_function?(language, kind) ->
        receiver = if this_rebinding?(language, kind), do: nil, else: state.receiver
        state = %{state | container_kind: :function_like, receiver: receiver}
        walk(child, source, language, lang_ctx, state, acc)

      true ->
        process_scope_child(child, kind, source, language, lang_ctx, state, acc)
    end
  end

  defp process_scope_child(child, kind, source, language, lang_ctx, state, acc) do
    cond do
      this_rebinding?(language, kind) ->
        walk(child, source, language, lang_ctx, %{state | receiver: nil}, acc)

      python_self_lambda?(child, kind, source, language) ->
        walk_python_lambda(child, source, language, lang_ctx, state, acc)

      language == "ruby" and kind == "singleton_class" ->
        walk_ruby_singleton_class(child, source, language, lang_ctx, state, acc)

      java_anonymous_class_body?(language, kind, child) ->
        state = %{state | container_kind: :class_like, receiver: nil}
        walk(child, source, language, lang_ctx, state, acc)

      true ->
        walk(child, source, language, lang_ctx, state, acc)
    end
  end

  # `class << expr`: `expr` is evaluated in the enclosing scope. `self` keeps the
  # enclosing class; a constant qualifies the body like `def Foo.x`; anything
  # else is an unresolvable object, so `self` inside has no class receiver.
  defp walk_ruby_singleton_class(node, source, language, lang_ctx, state, acc) do
    value = TS.node_child_by_field_name(node, "value")
    body = TS.node_child_by_field_name(node, "body")
    acc = walk_nodes(List.wrap(value), source, language, lang_ctx, state, acc)

    inner =
      case value && TS.node_kind(value) do
        "self" ->
          state

        kind when kind in ["constant", "scope_resolution"] ->
          {base, text} =
            case slice(source, value) do
              "::" <> rooted -> {[], rooted}
              text -> {state.scope, text}
            end

          segs = text |> ruby_dotted() |> String.split(".")

          scope =
            if List.starts_with?(Enum.reverse(base), Enum.reverse(segs)),
              do: base,
              else: base ++ segs

          %{state | scope: scope, receiver: Enum.join(scope, ".")}

        _ ->
          %{state | receiver: nil}
      end

    walk_nodes(List.wrap(body), source, language, lang_ctx, inner, acc)
  end

  # `lambda self: ...` shadows the receiver in its body; parameter defaults are
  # evaluated in the enclosing scope.
  defp python_self_lambda?(node, "lambda", source, "python") do
    case TS.node_child_by_field_name(node, "parameters") do
      nil -> false
      params -> params |> named_children() |> Enum.any?(&self_param?(&1, source))
    end
  end

  defp python_self_lambda?(_node, _kind, _source, _language), do: false

  defp walk_python_lambda(node, source, language, lang_ctx, state, acc) do
    params = TS.node_child_by_field_name(node, "parameters")
    body = TS.node_child_by_field_name(node, "body")
    acc = walk(params, source, language, lang_ctx, state, acc)
    walk_nodes(List.wrap(body), source, language, lang_ctx, %{state | receiver: nil}, acc)
  end

  # Ordinary js/ts functions bind their own `this`; arrow functions inherit
  # it lexically, so only the former drop the enclosing class receiver.
  defp this_rebinding?(language, kind) when language in ["javascript", "typescript"],
    do:
      kind in ~w(function_declaration generator_function_declaration function_expression generator_function)

  defp this_rebinding?(_language, _kind), do: false

  # Arrow functions have no name field and emit no entity but are function-like
  # containers, so a nested named function is a :function, not a :method of the
  # enclosing class. (Function expressions are definitions: named ones emit an
  # entity, anonymous ones fall through the nil-name path.)
  defp anonymous_function?(language, kind) when language in ["javascript", "typescript"],
    do: kind == "arrow_function"

  defp anonymous_function?(_language, _kind), do: false

  # `new T() { ... }` and enum constant bodies (`PLUS { ... }`): the body has
  # no graph identity, so `this` inside it must not resolve to the enclosing
  # class.
  defp java_anonymous_class_body?("java", "class_body", node) do
    case TS.node_parent(node) do
      nil -> false
      parent -> TS.node_kind(parent) in ["object_creation_expression", "enum_constant"]
    end
  end

  defp java_anonymous_class_body?(_language, _kind, _node), do: false

  # An object-literal method binds `this` to the object, not the class.
  defp object_literal_method?(node) do
    with "method_definition" <- TS.node_kind(node),
         parent when not is_nil(parent) <- TS.node_parent(node) do
      TS.node_kind(parent) == "object"
    else
      _ -> false
    end
  end

  defp maybe_walk(acc, child, source, language, lang_ctx, state) do
    if at_cap?(acc), do: acc, else: walk(child, source, language, lang_ctx, state, acc)
  end

  # --- definitions -----------------------------------------------------

  # Go names a method by its receiver type, not by nesting (a
  # method_declaration is a top-level tree node -- its receiver lives in a
  # separate `receiver:` field, never inside the receiver type's own AST
  # node the way a method sits inside a class body in every other
  # class-like language here). Without this, `func (A) Run()` and `func (B)
  # Run()` both name an entity bare "Run", colliding into one. Resolving the
  # receiver type gives `<ReceiverType>.<name>` (:method_like forces entity
  # kind :method regardless of container_kind -- the usual
  # function-nested-in-a-class-like-container rule can never fire here,
  # since go methods are never nested that way). When the receiver shape is
  # unresolvable (should not happen for valid go, but tree-sitter recovers
  # from invalid syntax with unexpected shapes), this falls back to the
  # bare, unqualified :function behavior from before this fix rather than
  # crashing.
  defp handle_definition(
         child,
         "method_declaration" = kind,
         source,
         "go" = language,
         lang_ctx,
         state,
         acc
       ) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)
    name = name_field(child, language, kind, source)

    case name && go_receiver_type_name(child, source) do
      nil ->
        handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)

      receiver_type ->
        qualified_name = receiver_type <> "." <> name

        handle_definition_category(
          child,
          :method_like,
          qualified_name,
          source,
          language,
          lang_ctx,
          state,
          acc
        )
    end
  end

  # Go's `type_declaration` covers both `type Foo struct{}` (one `type_spec`
  # child) and a grouped `type ( A struct{}; B struct{} )` block (several
  # `type_spec` children directly under the same `type_declaration` -- the
  # parens are pure syntax, with no wrapping AST node of their own;
  # empirically verified). Treating the whole `type_declaration` as ONE
  # entity (the pre-fix behavior, via `name_field/4`'s dedicated
  # "type_declaration" clause finding only the FIRST type_spec) silently
  # dropped every additional grouped type after the first: their subtrees
  # still got walked, but folded under the first spec's scope instead of
  # becoming their own entities. Each `type_spec` now gets its own
  # `handle_definition_category/8` pass -- scoped under the `type_spec`
  # node itself, not the shared `type_declaration`, so each spec's own
  # subtree (its `type:` field) is what gets walked as that entity's body.
  # A single `type Foo struct{}` has exactly one type_spec, so this loop
  # runs its body exactly once -- unchanged behavior for that case.
  defp handle_definition(
         child,
         "type_declaration" = kind,
         source,
         "go" = language,
         lang_ctx,
         state,
         acc
       ) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)

    child
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) in ["type_spec", "type_alias"]))
    |> Enum.reduce_while(acc, fn spec, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        name = name_field(spec, language, TS.node_kind(spec), source)

        {:cont,
         handle_definition_category(spec, category, name, source, language, lang_ctx, state, acc)}
      end
    end)
  end

  # Rust's `impl_item` covers both an inherent impl (`impl Foo { ... }`, no
  # "trait:" field -- `name_field/4`'s dedicated "impl_item" clause below
  # already names this bare `<Type>` correctly) and a trait impl (`impl
  # Display for Foo { fn fmt ... }`, "trait:" field present). Two different
  # traits impl'd for the same type both defining same-named methods (`impl
  # Display for Foo { fn fmt }` and `impl Debug for Foo { fn fmt }`) used to
  # collide on one bare "Foo" entity, both producing "Foo.fmt". When a
  # "trait:" field is present, the entity (and everything nested under it,
  # e.g. its methods) is scoped `<Type>.<Trait>` instead -- disambiguating
  # same-named trait methods across different traits without needing full
  # type resolution. `rust_trait_name/2` resolves the trait field's rightmost
  # type identifier for the generic (`impl<T> From<T> for Foo<T>` ->
  # "From") and path (`impl std::fmt::Display for Foo` -> "Display") shapes,
  # in addition to the plain `impl Display for Foo` case.
  defp handle_definition(
         child,
         "impl_item" = kind,
         source,
         "rust" = language,
         lang_ctx,
         state,
         acc
       ) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)

    {scope, type_name} =
      case name_field(child, language, kind, source) do
        nil -> {state.scope, nil}
        raw -> rust_resolve_path(raw, state)
      end

    state = %{state | scope: scope}

    trait_name =
      case TS.node_child_by_field_name(child, "trait") do
        nil -> nil
        trait_node -> rust_trait_name(trait_node, source)
      end

    # A type without path identity makes the trait the container; with neither
    # there is no impl scope segment.
    name =
      case {type_name, trait_name} do
        {nil, trait} -> trait
        {type, nil} -> type
        {type, trait} -> type <> "." <> trait
      end

    # Trait-qualified scope names the definitions, but `self.x()` resolves to
    # the impl's TYPE, where the inherent members live.
    state = %{state | self_target: type_name}
    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  # `class A::B` / `module A::B` name a `scope_resolution`; normalize to the
  # dotted form nested declarations use. A leading `::` is rooted: it ignores
  # the lexical scope.
  defp handle_definition(child, kind, source, "ruby" = language, lang_ctx, state, acc)
       when kind in ["class", "module"] do
    category = Map.fetch!(lang_ctx.def_kinds, kind)
    raw = name_field(child, language, kind, source)

    {state, name} =
      case raw do
        "::" <> rooted -> {%{state | scope: []}, ruby_dotted(rooted)}
        nil -> {state, nil}
        _ -> {state, ruby_dotted(raw)}
      end

    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  # Ruby `def A.run` qualifies the method by its statically named receiver
  # (`self` receivers keep the enclosing-class behavior of the generic clause).
  defp handle_definition(
         child,
         "singleton_method" = kind,
         source,
         "ruby" = language,
         lang_ctx,
         state,
         acc
       ) do
    name = name_field(child, language, kind, source)
    object = TS.node_child_by_field_name(child, "object")

    if name && object && TS.node_kind(object) in ["constant", "scope_resolution"] do
      receiver = source |> slice(object) |> ruby_dotted()

      # A receiver naming the enclosing class itself (`class C; def C.run`)
      # is already in the lexical scope; don't prefix it twice.
      {state, method_name} =
        if List.starts_with?(
             Enum.reverse(state.scope),
             Enum.reverse(String.split(receiver, "."))
           ),
           do: {state, name},
           else: {%{state | self_target: receiver}, receiver <> "." <> name}

      handle_definition_category(
        child,
        :method_like,
        method_name,
        source,
        language,
        lang_ctx,
        state,
        acc
      )
    else
      # `def other.run`: `self` inside is an unresolvable object.
      state =
        if object && TS.node_kind(object) != "self", do: %{state | receiver: nil}, else: state

      handle_definition_category(
        child,
        :function_like,
        name,
        source,
        language,
        lang_ctx,
        state,
        acc
      )
    end
  end

  # A `def` nested in another method defines a method on the containing class,
  # not on the enclosing method.
  defp handle_definition(
         child,
         "method" = kind,
         source,
         "ruby" = language,
         lang_ctx,
         %{container_kind: container, receiver: receiver} = state,
         acc
       )
       when container in [:function_like, :method_like] and is_binary(receiver) do
    name = name_field(child, language, kind, source)
    state = %{state | scope: String.split(receiver, ".")}
    handle_definition_category(child, :method_like, name, source, language, lang_ctx, state, acc)
  end

  defp handle_definition(child, kind, source, language, lang_ctx, state, acc) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)
    name = name_field(child, language, kind, source)
    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  # Resolves a rooted impl path against the enclosing MODULE path (`mod_scope`,
  # never function/impl names): `crate::` restarts at the crate root, `self::`
  # stays in the current module, each `super::` pops one module. Any other path
  # is relative to the lexical `scope`.
  defp rust_resolve_path(dotted, %{scope: scope, mod_scope: mod_scope}) do
    {scope, segs} =
      case String.split(dotted, ".") do
        ["crate" | rest] -> {[], rest}
        ["self" | rest] -> {mod_scope, rest}
        ["super" | _] = segs -> rust_pop_supers(segs, mod_scope)
        segs -> {scope, segs}
      end

    {scope, Enum.join(segs, ".")}
  end

  defp rust_pop_supers(["super" | rest], scope), do: rust_pop_supers(rest, Enum.drop(scope, -1))
  defp rust_pop_supers(segs, scope), do: {scope, segs}

  # Resolves a rust `impl_item`'s "trait:" field to the trait's own bare
  # name -- the rightmost type identifier, regardless of how the trait path
  # is written. A plain trait reference IS the type_identifier already
  # (`Display`). A generic trait reference (`From<T>`) is a `generic_type`
  # wrapping a "type:" field, recursed into (drops the type arguments,
  # qualified by the trait's base name only -- same convention as
  # `go_unwrap_receiver_type/2`'s generic-receiver handling). A
  # module-qualified trait reference (`std::fmt::Display`) is a
  # `scoped_type_identifier` whose "name:" field is already the rightmost
  # segment directly, no recursion needed. All three shapes empirically
  # verified. Any other/unresolvable shape returns nil so the caller falls
  # back to the bare `<Type>` scope rather than crashing.
  defp rust_trait_name(trait_node, source) do
    case TS.node_kind(trait_node) do
      "type_identifier" ->
        slice(source, trait_node)

      "generic_type" ->
        case TS.node_child_by_field_name(trait_node, "type") do
          nil -> nil
          inner -> rust_trait_name(inner, source)
        end

      "scoped_type_identifier" ->
        case TS.node_child_by_field_name(trait_node, "name") do
          nil -> nil
          name_node -> slice(source, name_node)
        end

      _ ->
        nil
    end
  end

  # `receiver:` -> `parameter_list` -> exactly one `parameter_declaration`
  # (go permits no more; empirically verified) whose `type:` field names the
  # receiver type. That field is either a bare `type_identifier` (`func (a
  # A) Run()`), a `pointer_type` wrapping one (`func (a *A) Run()` -- its
  # type_identifier is a plain positional child there, not a field itself,
  # empirically verified), or a `generic_type` (`func (g Generic[T])
  # Run()`) whose own `type:` field is the base type_identifier (type
  # arguments discarded -- qualified by the generic type's base name only).
  # Any other shape returns nil so the caller falls back to bare naming.
  defp go_receiver_type_name(method_node, source) do
    with receiver_node when not is_nil(receiver_node) <-
           TS.node_child_by_field_name(method_node, "receiver"),
         [param_decl] <- named_children(receiver_node),
         type_node when not is_nil(type_node) <- TS.node_child_by_field_name(param_decl, "type") do
      go_unwrap_receiver_type(type_node, source)
    else
      _ -> nil
    end
  end

  defp go_unwrap_receiver_type(type_node, source) do
    case TS.node_kind(type_node) do
      "type_identifier" ->
        slice(source, type_node)

      "pointer_type" ->
        case named_children(type_node) do
          [inner] -> go_unwrap_receiver_type(inner, source)
          _ -> nil
        end

      "generic_type" ->
        case TS.node_child_by_field_name(type_node, "type") do
          nil -> nil
          inner -> go_unwrap_receiver_type(inner, source)
        end

      _ ->
        nil
    end
  end

  # Scope/qname/receiver threading, identical once `category` and `name`
  # are known regardless of how they were derived.
  defp handle_definition_category(child, category, name, source, language, lang_ctx, state, acc) do
    # A name that can't be emitted (oversized, or carrying control characters)
    # must never become scope, `from` or receiver either: the definition is
    # treated as anonymous, so every `from` names an emitted entity.
    name = if name && emittable_name?(Enum.join(state.scope ++ [name], ".")), do: name

    {new_scope, new_enclosing_qname, new_receiver, acc} =
      case name do
        nil ->
          {state.scope, state.enclosing_qname, unnamed_receiver(category, state), acc}

        _ ->
          qname = Enum.join(state.scope ++ [name], ".")
          entity_kind = entity_kind_for(category, state.container_kind)
          entity = %{qualified_name: qname, kind: entity_kind, line: line(child)}

          receiver =
            if receiver_owner?(category, state.self_target),
              do: Enum.join(state.scope ++ [state.self_target || name], "."),
              else: state.receiver

          {state.scope ++ [name], qname, receiver, add_entity(acc, entity)}
      end

    {new_receiver, pending_receiver} =
      python_class_receiver(language, category, state, new_receiver, child, source)

    pending_receiver = unresolved_if_anonymous_class(pending_receiver, language, category, name)

    if at_cap?(acc) do
      acc
    else
      new_state = %WalkState{
        scope: new_scope,
        mod_scope: next_mod_scope(state.mod_scope, language, category, name),
        container_kind: category,
        enclosing_qname: new_enclosing_qname,
        receiver:
          if(receiver_boundary?(child, source, language, category, name, state),
            do: nil,
            else: new_receiver
          ),
        pending_receiver: pending_receiver,
        self_target: nil
      }

      walk_definition(child, category, language, source, lang_ctx, state, new_state, acc)
    end
  end

  # A singleton method whose own name was rejected still binds its explicit
  # receiver (`def A.<oversized>` binds `A`); a receiver that is itself not
  # emittable is unresolvable, so `self` inside has no receiver.
  defp unnamed_receiver(:method_like, %WalkState{self_target: target} = state)
       when is_binary(target) do
    receiver = Enum.join(state.scope ++ [target], ".")
    if emittable_name?(receiver), do: receiver
  end

  defp unnamed_receiver(_category, state), do: state.receiver

  # A class heritage (`extends <expr>`) is evaluated in the ENCLOSING scope, and
  # so are the computed keys of its members.
  defp walk_js_class(node, source, language, lang_ctx, outer_state, inner_state, acc) do
    Enum.reduce_while(named_children(node), acc, fn child, acc ->
      acc =
        case TS.node_kind(child) do
          "class_heritage" ->
            process_child(child, source, language, lang_ctx, outer_state, acc)

          "class_body" ->
            walk_js_class_body(child, source, language, lang_ctx, outer_state, inner_state, acc)

          _ ->
            process_child(child, source, language, lang_ctx, inner_state, acc)
        end

      if at_cap?(acc), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp walk_js_class_body(body, source, language, lang_ctx, outer_state, inner_state, acc) do
    Enum.reduce_while(named_children(body), acc, fn member, acc ->
      {keys, rest} = Enum.split_with(named_children(member), &computed_key?/1)
      acc = walk_nodes(keys, source, language, lang_ctx, outer_state, acc)

      acc =
        cond do
          at_cap?(acc) ->
            acc

          Map.has_key?(lang_ctx.def_kinds, TS.node_kind(member)) ->
            keys_state = %{inner_state | keys_done: true}
            process_child(member, source, language, lang_ctx, keys_state, acc)

          true ->
            walk_nodes(rest, source, language, lang_ctx, inner_state, acc)
        end

      if at_cap?(acc), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp computed_key?(node), do: TS.node_kind(node) == "computed_property_name"

  # Entering a python class does not bind `self`: its direct statements keep the
  # outer receiver and only functions defined directly in the body get the
  # class (held in `pending_receiver` meanwhile) as theirs.
  defp python_class_receiver("python", :class_like, state, receiver, _node, _source),
    do: {state.receiver, receiver}

  defp python_class_receiver(
         "python",
         :function_like,
         %{container_kind: :class_like} = state,
         _,
         node,
         source
       ) do
    if python_binds_self?(node, source),
      do: {self_receiver(state), nil},
      else: {state.receiver, nil}
  end

  defp python_class_receiver(_language, _category, _state, receiver, _node, _source),
    do: {receiver, nil}

  # A python class whose name was rejected (not emittable) has no identity for
  # `self` in its methods to resolve to: they stay unresolved, never falling
  # back to an outer receiver. Its BODY still keeps the outer receiver.
  defp unresolved_if_anonymous_class(_pending, "python", :class_like, nil), do: :unresolved
  defp unresolved_if_anonymous_class(pending, _language, _category, _name), do: pending

  defp self_receiver(%WalkState{pending_receiver: :unresolved}), do: nil
  defp self_receiver(%WalkState{pending_receiver: nil, receiver: receiver}), do: receiver
  defp self_receiver(%WalkState{pending_receiver: pending}), do: pending

  defp python_binds_self?(node, source) do
    case TS.node_child_by_field_name(node, "parameters") do
      nil -> false
      params -> params |> named_children() |> Enum.any?(&self_param?(&1, source))
    end
  end

  # Python evaluates a definition's header (parameter defaults, annotations,
  # class bases) in the ENCLOSING scope (outer receiver and `from`); only the
  # body sees the new scope (and a rebound `self`, per the inner state).
  defp walk_python_def(node, source, language, lang_ctx, outer_state, inner_state, acc) do
    header_fields =
      if TS.node_kind(node) == "class_definition",
        do: ["superclasses"],
        else: ["parameters", "return_type"]

    outer = Enum.map(header_fields, &TS.node_child_by_field_name(node, &1))
    acc = walk_nodes(Enum.reject(outer, &is_nil/1), source, language, lang_ctx, outer_state, acc)
    body = TS.node_child_by_field_name(node, "body")
    walk_nodes(List.wrap(body), source, language, lang_ctx, inner_state, acc)
  end

  defp receiver_owner?(category, _self_target) when category in [:class_like, :module_like],
    do: true

  defp receiver_owner?(:method_like, self_target), do: not is_nil(self_target)
  defp receiver_owner?(_category, _self_target), do: false

  defp next_mod_scope(mod_scope, "rust", :module_like, name) when is_binary(name),
    do: mod_scope ++ [name]

  defp next_mod_scope(mod_scope, _language, _category, _name), do: mod_scope

  # Definitions that bind their own `this`, or (unnamed classes) have no graph
  # identity to resolve a receiver to.
  defp receiver_boundary?(node, source, language, category, name, state) do
    this_rebinding?(language, TS.node_kind(node)) or object_literal_method?(node) or
      anonymous_container?(name, category, language) or
      python_rebinds_self?(node, source, language, state)
  end

  # An unnamed (or rejected-name) class or module has no identity for `self` to
  # resolve to, in every language; except a Python class body, which never binds
  # `self` at all and keeps the outer receiver (its methods are handled via
  # `:unresolved` pending_receiver).
  defp anonymous_container?(nil, :class_like, "python"), do: false

  defp anonymous_container?(nil, category, _language)
       when category in [:class_like, :module_like],
       do: true

  defp anonymous_container?(_name, _category, _language), do: false

  # A python function nested in a function (not a direct method) that takes its
  # own `self` parameter shadows the outer receiver.
  defp python_rebinds_self?(node, source, "python", %{container_kind: container})
       when container != :class_like do
    python_binds_self?(node, source)
  end

  defp python_rebinds_self?(_node, _source, _language, _state), do: false

  defp self_param?(param, source) do
    target =
      if TS.node_kind(param) == "identifier",
        do: param,
        else: param |> named_children() |> List.first()

    target != nil and TS.node_kind(target) == "identifier" and slice(source, target) == "self"
  end

  defp walk_definition(node, _category, "python", source, lang_ctx, outer, inner, acc),
    do: walk_python_def(node, source, "python", lang_ctx, outer, inner, acc)

  defp walk_definition(node, :class_like, lang, source, lang_ctx, outer, inner, acc)
       when lang in ["javascript", "typescript"],
       do: walk_js_class(node, source, lang, lang_ctx, outer, inner, acc)

  # A class member's computed key was already walked in the class's enclosing state.
  defp walk_definition(
         node,
         _category,
         lang,
         source,
         lang_ctx,
         %WalkState{keys_done: true},
         inner,
         acc
       )
       when lang in ["javascript", "typescript"] do
    children = node |> named_children() |> Enum.reject(&computed_key?/1)
    walk_nodes(children, source, lang, lang_ctx, inner, acc)
  end

  # Any other js/ts definition (e.g. an object-literal method): a computed key is
  # evaluated in the scope enclosing the definition, its body in the new scope.
  defp walk_definition(node, _category, lang, source, lang_ctx, outer, inner, acc)
       when lang in ["javascript", "typescript"] do
    {keys, rest} = node |> named_children() |> Enum.split_with(&computed_key?/1)
    acc = walk_nodes(keys, source, lang, lang_ctx, outer, acc)
    walk_nodes(rest, source, lang, lang_ctx, inner, acc)
  end

  # A ruby superclass expression is evaluated in the ENCLOSING scope.
  defp walk_definition(node, :class_like, "ruby", source, lang_ctx, outer, inner, acc) do
    Enum.reduce(named_children(node), acc, fn child, acc ->
      state = if TS.node_kind(child) == "superclass", do: outer, else: inner
      walk_nodes([child], source, "ruby", lang_ctx, state, acc)
    end)
  end

  # An elixir def's head (`f(x)`, `f(x) when g(x)`, default arguments) parses as
  # an ordinary nested `call`, indistinguishable from a call site, so only the
  # body is walked: the `do_block`, or the value of the keyword form
  # (`def f(x), do: expr`).
  defp walk_definition(node, :function_like, "elixir", source, lang_ctx, _outer, inner, acc) do
    # Default values (`x \\ helper()`) are executable: evaluated when the
    # function is called without that argument, so they belong to it.
    acc = walk_nodes(elixir_default_values(node, source), source, "elixir", lang_ctx, inner, acc)

    node
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) in ["do_block", "arguments"]))
    |> Enum.reduce_while(acc, fn child, acc ->
      if at_cap?(acc),
        do: {:halt, acc},
        else: {:cont, walk_elixir_def_body_node(child, source, lang_ctx, inner, acc)}
    end)
  end

  # Walks the whole definition node: these grammars give the parameter list its
  # own dedicated node kind, so there's no ambiguity to worry about.
  defp walk_definition(node, _category, lang, source, lang_ctx, _outer, inner, acc),
    do: walk(node, source, lang, lang_ctx, inner, acc)

  defp entity_kind_for(:class_like, _container), do: :class
  defp entity_kind_for(:module_like, _container), do: :module
  defp entity_kind_for(:method_like, _container), do: :method
  defp entity_kind_for(:function_like, :class_like), do: :method
  defp entity_kind_for(:function_like, _container), do: :function

  # --- elixir ---------------------------------------------------------------

  # The identifier on the right of `x |> name` (no parens), or nil. Anything else
  # there (a `call`, `Mod.fun`) is already a call node handled normally.
  defp bare_pipe_callee(node, source) do
    with "binary_operator" <- TS.node_kind(node),
         op when not is_nil(op) <- TS.node_child_by_field_name(node, "operator"),
         "|>" <- slice(source, op),
         right when not is_nil(right) <- TS.node_child_by_field_name(node, "right") do
      elixir_identifier(right, source)
    else
      _ -> nil
    end
  end

  defp walk_elixir_def_body_node(node, source, lang_ctx, state, acc) do
    case TS.node_kind(node) do
      "do_block" ->
        walk(node, source, "elixir", lang_ctx, state, acc)

      "arguments" ->
        node
        |> named_children()
        |> Enum.filter(&(TS.node_kind(&1) == "keywords"))
        |> Enum.flat_map(&named_children/1)
        |> Enum.flat_map(&List.wrap(TS.node_child_by_field_name(&1, "value")))
        |> walk_nodes(source, "elixir", lang_ctx, state, acc)
    end
  end

  defp handle_elixir_call(call_node, source, language, lang_ctx, state, acc) do
    target_node = TS.node_child_by_field_name(call_node, "target")
    target = elixir_identifier(target_node, source)

    cond do
      is_nil(target_node) ->
        walk(call_node, source, language, lang_ctx, state, acc)

      # `@name value`: the attribute-name call is not a callee, but a call in
      # its value is found. Checked first so `@use`/`@def` are not definitions.
      elixir_attribute_name_call?(call_node, source) ->
        if target in @elixir_typespec_attrs,
          do: acc,
          else: walk(call_node, source, language, lang_ctx, state, acc)

      target in @elixir_def_forms ->
        handle_elixir_definition(call_node, target, source, language, lang_ctx, state, acc)

      # The form itself is only an import; calls in its arguments or block
      # (`use Foo, opts: build()`) are still dependencies.
      target in @elixir_import_forms ->
        call_node
        |> handle_elixir_import(source, state, acc)
        |> then(&maybe_walk(&1, call_node, source, language, lang_ctx, state))

      true ->
        acc
        |> handle_elixir_call_ref(call_node, target_node, source, state)
        |> maybe_walk(call_node, source, language, lang_ctx, state)
    end
  end

  defp elixir_identifier(nil, _source), do: nil

  defp elixir_identifier(node, source),
    do: if(TS.node_kind(node) == "identifier", do: slice(source, node))

  # `@moduledoc "x"` parses as `unary_operator(operator: "@", operand: call)`;
  # the operand is the attribute name, not a call. The operator FIELD is
  # checked because every unary operator (`!`, `not`, `-`) has the same kind.
  defp elixir_attribute_name_call?(call_node, source) do
    with parent when not is_nil(parent) <- TS.node_parent(call_node),
         "unary_operator" <- TS.node_kind(parent),
         op when not is_nil(op) <- TS.node_child_by_field_name(parent, "operator") do
      slice(source, op) == "@"
    else
      _ -> false
    end
  end

  # defimpl's generated module is `<Protocol>.<ForType>`, absolute: it is not
  # nested under the module it is written in, so scope restarts at []. `for:
  # [A, B]` is one full implementation per type, so the body is walked once per
  # name. With no resolvable target (`for: unquote(t)`, or no `for:` outside a
  # named module) the impl has no identity: anonymous, scope kept.
  defp handle_elixir_definition(child, "defimpl", source, language, lang_ctx, state, acc) do
    case elixir_defimpl_names(child, state, source) do
      [] ->
        handle_definition_category(
          child,
          :module_like,
          nil,
          source,
          language,
          lang_ctx,
          state,
          acc
        )

      names ->
        impl_state = %{state | scope: []}
        walk_defimpl_names(names, child, source, language, lang_ctx, impl_state, acc)
    end
  end

  defp handle_elixir_definition(child, target, source, language, lang_ctx, state, acc) do
    category = if target in @elixir_module_forms, do: :module_like, else: :function_like
    name = elixir_definition_name(child, category, source)

    # `defmodule Elixir.Shared` inside `Outer` is the absolute `Shared`.
    state =
      if category == :module_like and match?({_, true}, elixir_module_alias(child, source)),
        do: %{state | scope: []},
        else: state

    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  defp walk_defimpl_names(names, child, source, language, lang_ctx, impl_state, acc) do
    Enum.reduce_while(names, acc, fn name, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        acc =
          handle_definition_category(
            child,
            :module_like,
            name,
            source,
            language,
            lang_ctx,
            impl_state,
            acc
          )

        {:cont, acc}
      end
    end)
  end

  # The module name is the first argument when it is an alias (the grammar
  # makes `Foo.Bar` one dotted token), canonical per elixir_alias/2;
  # `defmodule unquote(m)` or `__MODULE__.Foo` name nothing.
  defp elixir_definition_name(call_node, :module_like, source) do
    case call_node |> elixir_module_alias(source) do
      {name, _rooted?} -> name
      nil -> nil
    end
  end

  defp elixir_definition_name(call_node, :function_like, source) do
    case elixir_arguments(call_node) do
      [first | _] -> elixir_def_name_from(first, source)
      [] -> nil
    end
  end

  defp elixir_module_alias(call_node, source) do
    case elixir_arguments(call_node) do
      [first | _] -> elixir_alias(first, source)
      [] -> nil
    end
  end

  # Module aliases are canonical: `Elixir.Foo` is the absolute `Foo` (rooted,
  # like Ruby's `::A`, so it never nests under the enclosing module). Returns
  # {name, rooted?} for an `alias` node, nil otherwise or for bare `Elixir`.
  defp elixir_alias(node, source) do
    if TS.node_kind(node) == "alias" do
      case slice(source, node) do
        "Elixir" -> nil
        "Elixir." <> rest -> {rest, true}
        name -> {name, false}
      end
    end
  end

  # The right-hand sides of `arg \\ default` in a def head (under any `when`).
  defp elixir_default_values(def_node, source) do
    with [head | _] <- elixir_arguments(def_node),
         call when not is_nil(call) <- elixir_head_call(head, source) do
      call
      |> elixir_arguments()
      |> Enum.flat_map(&elixir_default_value(&1, source))
    else
      _ -> []
    end
  end

  defp elixir_default_value(arg, source) do
    with "binary_operator" <- TS.node_kind(arg),
         op when not is_nil(op) <- TS.node_child_by_field_name(arg, "operator"),
         "\\\\" <- slice(source, op) do
      List.wrap(TS.node_child_by_field_name(arg, "right"))
    else
      _ -> []
    end
  end

  defp elixir_head_call(head, source) do
    case TS.node_kind(head) do
      "call" ->
        head

      "binary_operator" ->
        with op when not is_nil(op) <- TS.node_child_by_field_name(head, "operator"),
             "when" <- slice(source, op),
             left when not is_nil(left) <- TS.node_child_by_field_name(head, "left") do
          elixir_head_call(left, source)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp elixir_defimpl_names(call_node, state, source) do
    with [_ | _] = args <- elixir_arguments(call_node),
         protocol when not is_nil(protocol) <-
           elixir_definition_name(call_node, :module_like, source) do
      types =
        case elixir_defimpl_for_value(args, source) do
          nil -> List.wrap(state.receiver)
          value -> elixir_defimpl_types(value, state, source)
        end

      types |> Enum.uniq() |> Enum.map(&(protocol <> "." <> &1))
    else
      _ -> []
    end
  end

  defp elixir_defimpl_for_value(args, source) do
    args
    |> Enum.filter(&(TS.node_kind(&1) == "keywords"))
    |> Enum.flat_map(&named_children/1)
    |> Enum.find_value(fn pair ->
      with key when not is_nil(key) <- TS.node_child_by_field_name(pair, "key"),
           true <- String.starts_with?(slice(source, key), "for:") do
        TS.node_child_by_field_name(pair, "value")
      else
        _ -> nil
      end
    end)
  end

  # An alias, `__MODULE__` (the enclosing module), or a list of them.
  defp elixir_defimpl_types(node, state, source) do
    case TS.node_kind(node) do
      "alias" ->
        case elixir_alias(node, source) do
          {name, _rooted?} -> [name]
          nil -> []
        end

      "identifier" ->
        if slice(source, node) == "__MODULE__", do: List.wrap(state.receiver), else: []

      "list" ->
        node |> named_children() |> Enum.flat_map(&elixir_defimpl_types(&1, state, source))

      _ ->
        []
    end
  end

  # `arguments` is a positional child, not a field. Comments are named extras.
  defp elixir_arguments(call_node) do
    case call_node |> named_children() |> Enum.find(&(TS.node_kind(&1) == "arguments")) do
      nil -> []
      args -> args |> named_children() |> Enum.reject(&(TS.node_kind(&1) == "comment"))
    end
  end

  # A definition head: a bare identifier (`def init`), a call whose target is an
  # identifier (`def f(x)`), or a `when` guard around either. Anything else
  # (operators, `unquote(name)` splices, nested-call targets) has no static name.
  defp elixir_def_name_from(node, source) do
    case TS.node_kind(node) do
      "call" ->
        node
        |> TS.node_child_by_field_name("target")
        |> elixir_identifier(source)
        |> splice_free()

      "identifier" ->
        node |> elixir_identifier(source) |> splice_free()

      "binary_operator" ->
        with op when not is_nil(op) <- TS.node_child_by_field_name(node, "operator"),
             "when" <- slice(source, op),
             left when not is_nil(left) <- TS.node_child_by_field_name(node, "left") do
          elixir_def_name_from(left, source)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp splice_free(name), do: if(name not in @elixir_splice_forms, do: name)

  # `helper(x)` names `helper`; `Mod.fun(x)` and `__MODULE__.fun(x)` name the
  # rightmost member, never qualified (elixir has no self/this receiver).
  defp handle_elixir_call_ref(acc, call_node, target_node, source, state) do
    name =
      case TS.node_kind(target_node) do
        "identifier" -> slice(source, target_node)
        "dot" -> target_node |> TS.node_child_by_field_name("right") |> elixir_identifier(source)
        _ -> nil
      end

    if name,
      do:
        add_reference(acc, %{
          name: name,
          kind: :call,
          from: state.enclosing_qname,
          line: line(call_node)
        }),
      else: acc
  end

  # alias/import/use/require import their first argument when it is a module
  # alias; `alias Foo.{Bar, Baz}` is best-effort `Foo`.
  defp handle_elixir_import(call_node, source, state, acc) do
    name =
      case elixir_arguments(call_node) do
        [first | _] -> elixir_import_name(first, source)
        [] -> nil
      end

    if name,
      do:
        add_reference(acc, %{
          name: name,
          kind: :import,
          from: state.enclosing_qname,
          line: line(call_node)
        }),
      else: acc
  end

  defp elixir_import_name(node, source) do
    alias_node =
      case TS.node_kind(node) do
        "alias" -> node
        "dot" -> TS.node_child_by_field_name(node, "left")
        _ -> nil
      end

    case alias_node && elixir_alias(alias_node, source) do
      {name, _rooted?} -> name
      _ -> nil
    end
  end

  # --- calls -------------------------------------------------------------

  defp handle_call(child, source, language, state, acc) do
    case callee_name(child, source, language) do
      nil ->
        acc

      {name, self_receiver?} ->
        case ruby_import(child, source, language, name) do
          {:import, import_name} ->
            add_reference(acc, %{
              name: import_name,
              kind: :import,
              from: state.enclosing_qname,
              line: line(child)
            })

          :not_import ->
            add_reference(acc, %{
              name: scoped_callee_name(name, self_receiver?, state.receiver),
              kind: :call,
              from: state.enclosing_qname,
              line: line(child)
            })
        end
    end
  end

  # `self.helper()` / `this.helper()` -- the ONLY receiver shape that's
  # statically resolvable without type inference, since the receiver is
  # lexically the enclosing class. Scoped only when a class-like/module-like
  # ancestor is actually in scope (e.g. a top-level JS `this.x()` has none --
  # falls back to the bare name).
  defp scoped_callee_name(name, true, receiver) when is_binary(receiver),
    do: receiver <> "." <> name

  defp scoped_callee_name(name, _self_receiver?, _receiver), do: name

  defp callee_name(call_node, source, "python") do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node) do
      qualified_or_bare(fn_node, source, "attribute", "object", "attribute", &python_self?/2)
    end
  end

  defp callee_name(call_node, source, lang) when lang in ["javascript", "typescript"] do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node) do
      fn_node
      |> qualified_or_bare(source, "member_expression", "object", "property", &this_node?/2)
      |> decode_js_callee()
    end
  end

  defp callee_name(call_node, source, "go") do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node) do
      # Go has no `self`/`this` keyword (receivers are user-named), so the
      # object side is never scope-resolvable here.
      qualified_or_bare(fn_node, source, "selector_expression", "operand", "field", fn _, _ ->
        false
      end)
    end
  end

  defp callee_name(call_node, source, "rust") do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node),
         fn_node <- rust_unwrap_generic_callee(fn_node) do
      case TS.node_kind(fn_node) do
        "field_expression" ->
          rust_field_expression_callee(fn_node, source)

        "scoped_identifier" ->
          rust_scoped_callee(fn_node, source)

        "identifier" ->
          {slice(source, fn_node), false}

        _ ->
          nil
      end
    end
  end

  defp callee_name(call_node, source, "ruby") do
    with m_node when not is_nil(m_node) <- TS.node_child_by_field_name(call_node, "method") do
      self? =
        case TS.node_child_by_field_name(call_node, "receiver") do
          nil -> false
          recv_node -> TS.node_kind(recv_node) == "self"
        end

      {slice(source, m_node), self?}
    end
  end

  defp callee_name(call_node, source, "java") do
    with n_node when not is_nil(n_node) <- TS.node_child_by_field_name(call_node, "name") do
      self? =
        case TS.node_child_by_field_name(call_node, "object") do
          nil -> false
          obj_node -> TS.node_kind(obj_node) == "this"
        end

      {slice(source, n_node), self?}
    end
  end

  defp callee_name(_call_node, _source, _language), do: nil

  # Identifiers may spell characters as `\u` escapes (`this.h\u0065lper()`);
  # canonicalize callees exactly like definition names (decode_js_identifier/1).
  defp decode_js_callee({name, self?}), do: {decode_js_identifier(name), self?}
  defp decode_js_callee(nil), do: nil

  # `(helper)()` / `(this.helper)()`: grouping parentheses don't change the callee.
  defp callee_node(call_node) do
    case TS.node_child_by_field_name(call_node, "function") do
      nil -> nil
      fn_node -> unwrap_parenthesized(fn_node)
    end
  end

  defp unwrap_parenthesized(node) do
    with "parenthesized_expression" <- TS.node_kind(node),
         [inner | _] <- Enum.reject(named_children(node), &(TS.node_kind(&1) =~ "comment")) do
      unwrap_parenthesized(inner)
    else
      _ -> node
    end
  end

  # `parse::<u32>()` / `self.helper::<u32>()`: the callee is a
  # `generic_function` wrapping the real callee in its "function" field.
  defp rust_unwrap_generic_callee(fn_node) do
    with "generic_function" <- TS.node_kind(fn_node),
         inner when not is_nil(inner) <- TS.node_child_by_field_name(fn_node, "function") do
      inner |> unwrap_parenthesized() |> rust_unwrap_generic_callee()
    else
      _ -> fn_node
    end
  end

  defp rust_scoped_callee(fn_node, source) do
    case TS.node_child_by_field_name(fn_node, "name") do
      nil -> {fallback_last_segment(source, fn_node), false}
      name_node -> {slice(source, name_node), false}
    end
  end

  defp rust_field_expression_callee(fn_node, source) do
    self? =
      case TS.node_child_by_field_name(fn_node, "value") do
        nil -> false
        value_node -> TS.node_kind(value_node) == "self"
      end

    case TS.node_child_by_field_name(fn_node, "field") do
      nil -> {fallback_last_segment(source, fn_node), false}
      field_node -> {slice(source, field_node), self?}
    end
  end

  # Grammar-specific self-reference checks, used by `qualified_or_bare/6`.
  # Python has no dedicated `self` node kind -- `self` is a plain identifier,
  # so it takes a text comparison. JS/TS give `this` its own node kind, so a
  # kind check alone is enough (no text slice needed).
  defp python_self?(obj_node, source),
    do: TS.node_kind(obj_node) == "identifier" and slice(source, obj_node) == "self"

  defp this_node?(obj_node, _source), do: TS.node_kind(obj_node) == "this"

  # Shared shape for the qualified-callee grammars (python `attribute`, js/ts
  # `member_expression`, go `selector_expression`): if the callee subtree is
  # the qualified wrapper kind, resolve its rightmost field (plus whether its
  # object side is a self-reference per `self_pred`); otherwise it's already
  # a bare identifier, sliced directly (never a self-reference).
  defp qualified_or_bare(fn_node, source, wrapper_kind, object_field, member_field, self_pred) do
    if TS.node_kind(fn_node) == wrapper_kind do
      self? =
        case TS.node_child_by_field_name(fn_node, object_field) do
          nil -> false
          obj_node -> self_pred.(obj_node, source)
        end

      case TS.node_child_by_field_name(fn_node, member_field) do
        nil -> {fallback_last_segment(source, fn_node), false}
        field_node -> {slice(source, field_node), self?}
      end
    else
      if TS.node_kind(fn_node) == "identifier", do: {slice(source, fn_node), false}
    end
  end

  # Defensive fallback for the qualified-callee shapes: slice the whole callee
  # subtree and take the last `.`/`::`-separated segment. Also handles the
  # plain-identifier case (no separator -> the whole text is the segment), so
  # rust's `function:` field can share this single implementation. Never a
  # self-reference: reached only when the expected member field is missing.
  defp fallback_last_segment(source, node) do
    source
    |> slice(node)
    |> String.split(~r/\.|::/)
    |> List.last()
  end

  # Ruby has no import node kind; require/require_relative are plain `call`
  # nodes. Classify one as an import of its first string argument.
  defp ruby_import(call_node, source, "ruby", name)
       when name in ["require", "require_relative"] do
    with true <- ruby_kernel_receiver?(call_node, source),
         str when not is_nil(str) <- first_string_arg(call_node, source) do
      {:import, str}
    else
      _ -> :not_import
    end
  end

  defp ruby_import(_call_node, _source, _language, _name), do: :not_import

  defp ruby_kernel_receiver?(call_node, source) do
    case TS.node_child_by_field_name(call_node, "receiver") do
      nil -> true
      recv -> TS.node_kind(recv) == "self" or slice(source, recv) in ["Kernel", "::Kernel"]
    end
  end

  defp first_string_arg(call_node, source) do
    with args_node when not is_nil(args_node) <-
           TS.node_child_by_field_name(call_node, "arguments"),
         [str_node | _] <- Enum.filter(named_children(args_node), &(TS.node_kind(&1) == "string")),
         false <- Enum.any?(named_children(str_node), &(TS.node_kind(&1) == "interpolation")) do
      string_content(str_node, source)
    else
      _ -> nil
    end
  end

  defp string_content(str_node, source) do
    case Enum.find(named_children(str_node), &(TS.node_kind(&1) == "string_content")) do
      nil -> strip_quotes(slice(source, str_node))
      content_node -> slice(source, content_node)
    end
  end

  # --- imports -------------------------------------------------------------

  defp handle_import(child, source, language, state, acc) do
    child
    |> import_refs(source, language)
    |> Enum.reduce_while(acc, fn {name, ln}, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont,
         add_reference(acc, %{name: name, kind: :import, from: state.enclosing_qname, line: ln})}
      end
    end)
  end

  defp import_refs(node, source, "python") do
    case TS.node_kind(node) do
      "import_statement" ->
        node
        |> named_children()
        |> Enum.filter(&(TS.node_kind(&1) in ["dotted_name", "aliased_import"]))
        |> Enum.map(&python_import_name(&1, source))

      "import_from_statement" ->
        case TS.node_child_by_field_name(node, "module_name") do
          nil ->
            []

          mod_node ->
            ln = line(mod_node)
            module_ref = {slice(source, mod_node), ln}

            # `import_from_statement` repeats the "name:" field once per
            # imported symbol (`dotted_name` or, aliased, `aliased_import`) —
            # separate from the single "module_name:" field handled above.
            # Emitting these too is what makes `related_code` importers of a
            # symbol non-empty: only the module ref existed before. A
            # `wildcard_import` (`from x import *`) carries no field name, so
            # the "name" filter below already excludes it — nothing to name.
            symbol_refs =
              node
              |> children_with_field("name")
              |> Enum.filter(&(TS.node_kind(&1) in ["dotted_name", "aliased_import"]))
              |> Enum.map(&{python_import_symbol(&1, source), ln})

            [module_ref | symbol_refs]
        end

      _ ->
        []
    end
  end

  defp import_refs(node, source, lang) when lang in ["javascript", "typescript"] do
    case TS.node_child_by_field_name(node, "source") do
      nil ->
        []

      src_node ->
        ln = line(node)
        # The source is a string literal: decoded like any js/ts string value,
        # and omitted when it doesn't decode to a usable import path.
        module_refs =
          case js_import_path(js_string_value(src_node, source)) do
            nil -> []
            path -> [{path, ln}]
          end

        module_refs ++ js_import_symbol_refs(node, source, ln)
    end
  end

  # go/rust/java import refs already carry the imported symbol (go/rust: the
  # full package/use path is the meaningful "name" there; java: the imported
  # class/member's scoped identifier) — no separate per-symbol ref needed.
  defp import_refs(node, source, "go") do
    node
    |> collect_kind("import_spec")
    |> Enum.map(fn spec ->
      case TS.node_child_by_field_name(spec, "path") do
        nil -> nil
        path_node -> {strip_quotes(slice(source, path_node)), line(spec)}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Rust's `use_declaration` "argument:" field is one of (empirically
  # verified, all under one `use_declaration`):
  #   * `identifier` / `scoped_identifier` -- a single plain path
  #     (`use std::collections::HashMap;`). `scoped_identifier`'s own source
  #     text already IS the full dotted path (its "path:"/"name:" fields
  #     nest recursively but are never decomposed here) -- sliced whole, same
  #     as before this fix.
  #   * `use_list` / `scoped_use_list` -- a path prefix plus a brace-list of
  #     items (`use std::{fs, io};`), each item recursively any of these same
  #     shapes (`use std::{fs::File, io::{self, Read}}` nests a
  #     `scoped_use_list` inside the outer `use_list`). One concrete path is
  #     emitted per leaf item instead of the old single-ref-for-the-whole-tree
  #     best effort.
  #   * `use_as_clause` -- an alias (`use std::io::Result as IoResult;`,
  #     "path:"/"alias:" fields) -- the ORIGINAL "path:" is emitted, the
  #     alias is discarded, consistent with every other language's aliased-
  #     import handling in this module.
  #   * `use_wildcard` -- a glob (`use std::io::*;`, one positional child, no
  #     field name) -- the prefix path is emitted (`std::io`), not the glob
  #     itself.
  #   * bare `self` -- inside a list, refers to the enclosing prefix itself
  #     (`io::{self, Read}` imports `io` via the first item), not a literal
  #     "self" segment.
  # `rust_use_paths/3` walks this recursively, threading the accumulated
  # prefix down; every language-specific line above traces back to one of
  # its clauses.
  defp import_refs(node, source, "rust") do
    case TS.node_child_by_field_name(node, "argument") do
      nil ->
        []

      arg_node ->
        ln = line(node)
        arg_node |> rust_use_paths(nil, source) |> Enum.map(&{&1, ln})
    end
  end

  defp import_refs(node, source, "java") do
    name_node =
      node
      |> named_children()
      |> Enum.find(&(TS.node_kind(&1) in ["scoped_identifier", "identifier"]))

    case name_node do
      nil -> [{slice(source, node), line(node)}]
      n -> [{slice(source, n), line(n)}]
    end
  end

  defp import_refs(_node, _source, _language), do: []

  # Import paths may be relative (`./x`) or scoped (`@s/p`) but, like every
  # emitted name, contain no whitespace, quotes, backticks or parentheses.
  defp js_import_path(path) when is_binary(path) do
    if path != "" and not String.match?(path, ~r/[\s"'`()]/u), do: path
  end

  defp js_import_path(_path), do: nil

  defp rust_use_paths(node, prefix, source) do
    case TS.node_kind(node) do
      "use_list" -> rust_use_list_paths(node, prefix, source)
      "scoped_use_list" -> rust_scoped_use_list_paths(node, prefix, source)
      "use_as_clause" -> rust_use_as_clause_paths(node, prefix, source)
      "use_wildcard" -> rust_use_wildcard_paths(node, prefix, source)
      _ -> [rust_use_path_text(node, prefix, source)]
    end
  end

  defp rust_use_list_paths(node, prefix, source) do
    node
    |> named_children()
    |> Enum.reject(&(TS.node_kind(&1) in ["line_comment", "block_comment"]))
    |> Enum.flat_map(&rust_use_paths(&1, prefix, source))
  end

  defp rust_scoped_use_list_paths(node, prefix, source) do
    path_node = TS.node_child_by_field_name(node, "path")
    list_node = TS.node_child_by_field_name(node, "list")

    if path_node && list_node do
      rust_use_paths(list_node, rust_use_path_text(path_node, prefix, source), source)
    else
      []
    end
  end

  defp rust_use_as_clause_paths(node, prefix, source) do
    case TS.node_child_by_field_name(node, "path") do
      nil -> []
      path_node -> rust_use_paths(path_node, prefix, source)
    end
  end

  # `use_wildcard` always wraps exactly one child in valid rust (a path, or
  # bare `self` meaning "the accumulated prefix", per `rust_use_path_text/3`
  # below) -- the `_` branch is a defensive fallback for a shape that should
  # not happen but which tree-sitter's error recovery could still produce.
  # `List.wrap/1` turns a resolved prefix into a single-element list, or a
  # nil prefix (no path to fall back to) into `[]` rather than crashing.
  defp rust_use_wildcard_paths(node, prefix, source) do
    case named_children(node) do
      [inner] -> [rust_use_path_text(inner, prefix, source)]
      _ -> List.wrap(prefix)
    end
  end

  # Resolves one path-shaped node (identifier / scoped_identifier / bare
  # `self`) to concrete text, joined onto the accumulated `prefix` with
  # "::". Bare `self` means "the prefix itself" (`io::{self, ...}` imports
  # `io`), not the literal text "self" -- falls back to the literal only when
  # there is no accumulated prefix to substitute (an unqualified top-level
  # `self`, not reachable from valid rust `use` syntax but handled rather
  # than crashing).
  defp rust_use_path_text(node, prefix, source) do
    if TS.node_kind(node) == "self" do
      prefix || "self"
    else
      text = slice(source, node)
      if prefix, do: prefix <> "::" <> text, else: text
    end
  end

  # `import_statement`'s optional `import_clause` holds, in source order: a
  # bare default identifier (no field name), then either `named_imports`
  # (each `import_specifier` resolved to its ORIGINAL "name:" field, alias
  # ignored — same policy as python's aliased imports) or a `namespace_import`
  # (`* as ns`, which names no individual symbol and is skipped; the module
  # ref above already covers it).
  defp js_import_symbol_refs(node, source, ln) do
    node
    |> named_children()
    |> Enum.find(&(TS.node_kind(&1) == "import_clause"))
    |> case do
      nil -> []
      clause -> clause |> named_children() |> Enum.flat_map(&js_clause_child_refs(&1, source, ln))
    end
  end

  defp js_clause_child_refs(child, source, ln) do
    case TS.node_kind(child) do
      "identifier" ->
        [{decode_js_identifier(slice(source, child)), ln}]

      "named_imports" ->
        child
        |> named_children()
        |> Enum.filter(&(TS.node_kind(&1) == "import_specifier"))
        |> Enum.flat_map(&import_specifier_ref(&1, source, ln))

      _ ->
        []
    end
  end

  # Specifier names are canonical like every js/ts identifier; an ES2022 string
  # specifier (`{ "a-b" as x }`) is its decoded value when that is an
  # identifier, otherwise it names nothing.
  defp import_specifier_ref(spec, source, ln) do
    case TS.node_child_by_field_name(spec, "name") do
      nil ->
        []

      name_node ->
        name =
          if TS.node_kind(name_node) == "string",
            do: name_node |> js_string_value(source) |> literal_identifier(),
            else: decode_js_identifier(slice(source, name_node))

        if name, do: [{name, ln}], else: []
    end
  end

  defp python_import_name(n, source), do: {python_import_symbol(n, source), line(n)}

  # Aliased imports resolve to the ORIGINAL name (the `name:` field of
  # `aliased_import`), never the alias — consistent for both plain
  # `import a as b` and from-import symbols (`from m import a as b`).
  defp python_import_symbol(n, source) do
    case TS.node_kind(n) do
      "aliased_import" ->
        case TS.node_child_by_field_name(n, "name") do
          nil -> slice(source, n)
          name_node -> slice(source, name_node)
        end

      _ ->
        slice(source, n)
    end
  end

  defp collect_kind(node, kind) do
    node
    |> named_children()
    |> Enum.flat_map(fn child ->
      if TS.node_kind(child) == kind, do: [child], else: collect_kind(child, kind)
    end)
  end

  defp strip_quotes(text),
    do: text |> String.trim() |> String.trim("\"") |> String.trim("'") |> String.trim("`")

  # --- shared node/accumulator helpers ---------------------------------

  # Collect direct named children in one O(n) cursor pass (same pattern as
  # `TreeSitterImpl.named_children/1`: the indexed `node_named_child/2`
  # accessor rescans from the first child each call, O(n^2) over siblings).
  defp named_children(node) do
    cursor = TS.node_walk(node)

    if TS.treecursor_goto_first_child(cursor) do
      collect_siblings(cursor, [])
    else
      []
    end
  end

  defp collect_siblings(cursor, acc) do
    node = TS.treecursor_node(cursor)
    acc = if TS.node_is_named(node), do: [node | acc], else: acc

    if TS.treecursor_goto_next_sibling(cursor) do
      collect_siblings(cursor, acc)
    else
      Enum.reverse(acc)
    end
  end

  # Like `named_children/1`, but keeps only children bound to `field_name` in
  # the grammar. Needed where `node_child_by_field_name/2` isn't enough:
  # python's `import_from_statement` repeats the "name:" field once per
  # imported symbol, and `node_child_by_field_name` only ever returns the
  # first match.
  defp children_with_field(node, field_name) do
    cursor = TS.node_walk(node)

    if TS.treecursor_goto_first_child(cursor) do
      collect_field_siblings(cursor, field_name, [])
    else
      []
    end
  end

  defp collect_field_siblings(cursor, field_name, acc) do
    node = TS.treecursor_node(cursor)

    acc =
      if TS.node_is_named(node) and TS.treecursor_field_name(cursor) == field_name do
        [node | acc]
      else
        acc
      end

    if TS.treecursor_goto_next_sibling(cursor) do
      collect_field_siblings(cursor, field_name, acc)
    else
      Enum.reverse(acc)
    end
  end

  # Go's `type_declaration` (the chunk-boundary kind wrapping struct/interface/
  # alias decls) has no "name" field of its own — empirically the name lives
  # one level down, on its `type_spec` child(ren); the dedicated
  # handle_definition/7 clause above calls this with each `type_spec`
  # directly (kind "type_spec"), which falls through to the generic clause
  # below since a type_spec's own "name" field is directly reachable. Rust's
  # `impl_item` likewise has no "name" field; the closest analog is the
  # "type" field (the type being impl'd). Every other definition kind
  # exposes "name" directly.
  defp name_field(node, "rust", "impl_item", source) do
    case TS.node_child_by_field_name(node, "type") do
      nil -> nil
      type_node -> rust_impl_type_name(type_node, source)
    end
  end

  # A TS ambient module (`declare module "pkg-a" {}`) is named by its module
  # path string; keep it when the path is a hygienic symbol, else anonymous.
  defp name_field(node, "typescript", "module", source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> nil
      name_node -> module_path_name(name_node, source)
    end
  end

  defp name_field(node, language, _kind, source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> nil
      name_node -> definition_name_text(name_node, source, language)
    end
  end

  # js/ts definition names. A name node the PARSER recognised as an identifier
  # is taken as-is: Unicode identifiers, `#private` names (kept with their `#`,
  # matching the `C.#helper` callee `this.#helper()` resolves to) and TS
  # `namespace A.B` (`nested_identifier`). Only LITERAL member keys are
  # validated: a string literal (also inside `[...]`, ignoring comments) names
  # the member when its DECODED value (`js_string_value/2`) is an ECMAScript
  # IdentifierName. Anything else (`[expr]`, `"a b"`, numbers, undecodable
  # strings) yields nil, i.e. an anonymous function-like container.
  @js_identifier_nodes ~w(identifier property_identifier type_identifier private_property_identifier nested_identifier)

  # ECMAScript IdentifierName: ID_Start = L + Nl + Other_ID_Start (U+1885, U+1886,
  # U+2118, U+212E, U+309B, U+309C), minus Pattern_Syntax (U+2E2F); ID_Continue
  # adds Mn, Mc, Nd, Pc and Other_ID_Continue (U+00B7, U+0387, U+1369-U+1371,
  # U+19DA); JS also allows `$`, `_`, ZWNJ and ZWJ.
  @js_id_start ~S"\p{L}\p{Nl}\x{1885}\x{1886}\x{2118}\x{212E}\x{309B}\x{309C}$_"
  @js_id_continue @js_id_start <>
                    ~S"\p{Mn}\p{Mc}\p{Nd}\p{Pc}\x{00B7}\x{0387}\x{1369}-\x{1371}\x{19DA}\x{200C}\x{200D}"
  @js_identifier Regex.compile!(
                   "\\A(?!.*\\x{2E2F})[#{@js_id_start}][#{@js_id_continue}]*\\z",
                   "u"
                 )

  defp definition_name_text(name_node, source, language)
       when language in ["javascript", "typescript"] do
    case TS.node_kind(name_node) do
      kind when kind in @js_identifier_nodes ->
        name_node |> then(&slice(source, &1)) |> decode_js_identifier()

      "string" ->
        name_node |> js_string_value(source) |> literal_identifier()

      "computed_property_name" ->
        name_node |> computed_key_string(source) |> literal_identifier()

      _ ->
        nil
    end
  end

  defp definition_name_text(name_node, source, _language), do: slice(source, name_node)

  defp literal_identifier(text) when is_binary(text),
    do: if(text =~ @js_identifier, do: text)

  defp literal_identifier(_text), do: nil

  defp computed_key_string(node, source) do
    case node |> named_children() |> Enum.reject(&(TS.node_kind(&1) =~ "comment")) do
      [str] -> if TS.node_kind(str) == "string", do: js_string_value(str, source)
      _ -> nil
    end
  end

  # The decoded value of a js/ts string literal, from its `string_fragment` and
  # `escape_sequence` children (never by trimming quotes off the source text,
  # which would also strip quotes that are part of the value). nil when the
  # literal can't be decoded to valid UTF-8 (e.g. a lone surrogate escape).
  defp js_string_value(str_node, source) do
    str_node
    |> named_children()
    |> Enum.reduce_while([], fn child, acc ->
      case TS.node_kind(child) do
        "string_fragment" ->
          {:cont, [slice(source, child) | acc]}

        "escape_sequence" ->
          {:cont, Enum.reverse(List.wrap(decode_js_escape(slice(source, child)))) ++ acc}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      :error -> nil
      # Line continuations decode to ""; drop them so a surrogate pair split
      # by one (`\\uD835\\<newline>\\uDC9C`) still pairs.
      parts -> parts |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> join_js_parts([])
    end
  end

  # An identifier's `\uXXXX`/`\u{...}` escapes decoded to their characters (the
  # only escapes identifiers allow), so `h\u0065lper` and `helper` are one name.
  # Left as written if an escape doesn't decode to a valid character.
  defp decode_js_identifier(name) when is_binary(name) do
    if String.contains?(name, "\\u") do
      parts =
        Regex.split(~r/\\u\{[0-9A-Fa-f]+\}|\\u[0-9A-Fa-f]{4}/, name, include_captures: true)
        |> Enum.map(fn
          "\\u" <> _ = esc -> decode_js_escape(esc)
          text -> text
        end)

      join_js_parts(parts, []) || name
    else
      name
    end
  end

  # Code units from \u escapes may form UTF-16 surrogate pairs; combine them.
  defp join_js_parts([{:cu, hi}, {:cu, lo} | rest], acc)
       when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF,
       do: join_js_parts(rest, [<<0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)::utf8>> | acc])

  # An unpaired surrogate or an out-of-range escape: not a valid string value.
  defp join_js_parts([{:cu, :invalid} | _rest], _acc), do: nil
  defp join_js_parts([{:cu, cu} | _rest], _acc) when cu in 0xD800..0xDFFF, do: nil
  defp join_js_parts([{:cu, cu} | rest], acc), do: join_js_parts(rest, [<<cu::utf8>> | acc])
  defp join_js_parts([part | rest], acc), do: join_js_parts(rest, [part | acc])
  defp join_js_parts([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_js_escape("\\u{" <> rest), do: {:cu, rest |> String.trim_trailing("}") |> hex()}
  defp decode_js_escape("\\u" <> hex4), do: {:cu, hex(hex4)}
  defp decode_js_escape("\\x" <> hex2), do: {:cu, hex(hex2)}
  defp decode_js_escape("\\n"), do: "\n"
  defp decode_js_escape("\\t"), do: "\t"
  defp decode_js_escape("\\r"), do: "\r"
  defp decode_js_escape("\\b"), do: "\b"
  defp decode_js_escape("\\f"), do: "\f"
  defp decode_js_escape("\\v"), do: "\v"
  # Legacy octal escape (non-strict JS): a leading 0-3 takes up to three octal
  # digits, 4-7 up to two; the parser hands over the whole digit run, so any
  # surplus digit is literal text (`\477` is `'7`). `\0` alone is NUL; `\8` and
  # `\9` fall through to the identity escape below.
  defp decode_js_escape(<<"\\", d, digits::binary>>) when d in ?0..?7 do
    all = <<d>> <> digits

    if all =~ ~r/\A[0-7]+\z/ do
      {octal, rest} = String.split_at(all, if(d <= ?3, do: 3, else: 2))
      [{:cu, String.to_integer(octal, 8)}, rest]
    else
      all
    end
  end

  # A line continuation (backslash + line terminator) contributes nothing.
  defp decode_js_escape("\\" <> rest)
       when rest in ["\n", "\r\n", "\r", <<0x2028::utf8>>, <<0x2029::utf8>>],
       do: ""

  defp decode_js_escape("\\" <> char), do: char

  # Out-of-range code points (> U+10FFFF) can't be encoded: a distinct :invalid
  # marker that join_js_parts/2 rejects (never a pairable surrogate).
  defp hex(digits) do
    case Integer.parse(digits, 16) do
      {cp, ""} when cp <= 0x10FFFF -> cp
      _ -> :invalid
    end
  end

  # Module path strings (`pkg-a`, `@scope/pkg`) keep `-`, `@` and `/`, but must
  # still satisfy the output naming rules (see the moduledoc).
  defp module_path_name(name_node, source) do
    text = if TS.node_kind(name_node) == "string", do: js_string_value(name_node, source)

    if is_binary(text) and text != "" and not String.match?(text, ~r/[\s"'`()]/u) and
         not String.contains?(text, ["::", ".."]) and
         not (String.starts_with?(text, ".") or String.ends_with?(text, ".")),
       do: text
  end

  defp rust_dotted(path),
    do:
      path
      |> String.split("::")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(".")

  defp ruby_dotted(name), do: name |> String.split("::") |> Enum.map_join(".", &String.trim/1)

  # A Rust impl's type identity is its PATH type: references and pointers are
  # unwrapped to the pointee, generics to their base type. A type with no path
  # identity (tuple, array, slice, fn pointer, `dyn`, ...) yields nil.
  defp rust_impl_type_name(type_node, source) do
    case rust_path_type_node(type_node) do
      nil -> nil
      node -> source |> slice(node) |> rust_dotted()
    end
  end

  defp rust_path_type_node(node) do
    case TS.node_kind(node) do
      kind when kind in ["generic_type", "reference_type", "pointer_type"] ->
        case TS.node_child_by_field_name(node, "type") do
          nil -> nil
          inner -> rust_path_type_node(inner)
        end

      kind when kind in ["type_identifier", "scoped_type_identifier", "primitive_type"] ->
        node

      _ ->
        nil
    end
  end

  defp line(node), do: TS.node_start_position(node).row + 1

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    end_byte = TS.node_end_byte(node)
    if end_byte > start_byte, do: binary_part(source, start_byte, end_byte - start_byte), else: ""
  end

  defp at_cap?(acc), do: acc.count >= @max_items

  # The item cap, the symbol-size limit and storability are enforced HERE, at
  # the single choke point every emission goes through, so no traversal path can
  # exceed them; the `at_cap?/1` checks in the walkers are only early exits. A
  # definition whose name isn't emittable was already made anonymous in
  # handle_definition_category/8, so it never becomes scope or `from`.
  defp add_entity(%{count: count} = acc, _entity) when count >= @max_items, do: acc

  defp add_entity(acc, %{qualified_name: qname}) when byte_size(qname) > @max_symbol_bytes,
    do: acc

  defp add_entity(acc, %{qualified_name: qname} = entity) do
    if storable_name?(qname),
      do: %{acc | entities: [entity | acc.entities], count: acc.count + 1},
      else: acc
  end

  defp add_reference(%{count: count} = acc, _reference) when count >= @max_items, do: acc

  defp add_reference(acc, %{name: name}) when byte_size(name) > @max_symbol_bytes,
    do: acc

  defp add_reference(acc, %{name: name} = reference) do
    if storable_name?(name),
      do: %{acc | references: [reference | acc.references], count: acc.count + 1},
      else: acc
  end

  # Decoded names can carry control characters (`\x00`, `\0`); NUL can't be
  # stored in a Postgres text column, and no real symbol contains any C0/C1
  # control or DEL, so such a name is skipped for every language here.
  defp storable_name?(name), do: not String.match?(name, ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u)

  # What add_entity/2 would accept; definitions check it before entering scope.
  defp emittable_name?(name), do: byte_size(name) <= @max_symbol_bytes and storable_name?(name)
end
