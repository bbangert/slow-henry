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
  function bodies, because calls and imports live there. Two pieces of state
  thread down the walk:

    * `scope` — the list of enclosing NAMED definitions, joined with "." to
      build `qualified_name`.
    * `container_kind` — the category (`:function_like` / `:class_like` /
      `:module_like`) of the nearest enclosing definition, used to decide
      `:function` vs `:method` (a function-ish node directly inside a
      class-like container is a method).
    * `enclosing_qname` — the qualified_name of the nearest NAMED enclosing
      definition, used as `from` on references. An anonymous definition (no
      `name` field — e.g. a JS arrow function) does not become an entity and
      does not update `enclosing_qname`, but it DOES update `container_kind`
      so a method nested directly inside it is still classified correctly.
      Because `extract/3` walks exactly one already-parsed file's root node
      per call, `enclosing_qname` — and therefore every reference's `from` —
      can only ever name a definition from THIS file, never another file of
      the same source.
    * `class_qname` — the qualified_name of the nearest NAMED enclosing
      class-like/module-like definition (set on entering one, carried
      unchanged through nested function-likes so a method's inner helper
      still knows its class). Used to resolve `self.x()`/`this.x()` calls: in
      python/rust/ruby (`self`) and javascript/typescript/java (`this`), the
      receiver is statically the enclosing class -- no type inference needed
      -- so the callee name is scoped to `<class_qname>.<member>` instead of
      the bare rightmost member. Every other receiver shape keeps the
      rightmost-member best-effort below; full receiver resolution would
      require type inference, deliberately out of scope.

  Defensive cap: at most `@max_items` combined entities+references are
  collected per file; a generated/minified file could otherwise produce
  millions of rows downstream. Collection (and further descent into the
  subtree that would exceed it) stops once the cap is hit.
  """

  @behaviour RetrievalNode.Graph.Extractor

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

  @impl true
  def extract({root, source}, language, _opts) do
    def_kinds = Map.get(@definition_kinds, language, %{})
    call_kind = Map.get(@call_kinds, language)
    import_kinds = Map.get(@import_kinds, language, [])
    lang_ctx = %{def_kinds: def_kinds, call_kind: call_kind, import_kinds: import_kinds}

    state = %{
      scope: [],
      mod_scope: [],
      container_kind: nil,
      enclosing_qname: nil,
      class_qname: nil,
      pending_class: nil,
      self_name: nil
    }

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
        class_qname = if this_rebinding?(language, kind), do: nil, else: state.class_qname
        state = %{state | container_kind: :function_like, class_qname: class_qname}
        walk(child, source, language, lang_ctx, state, acc)

      true ->
        process_scope_child(child, kind, source, language, lang_ctx, state, acc)
    end
  end

  defp process_scope_child(child, kind, source, language, lang_ctx, state, acc) do
    cond do
      this_rebinding?(language, kind) ->
        walk(child, source, language, lang_ctx, %{state | class_qname: nil}, acc)

      python_self_lambda?(child, kind, source, language) ->
        walk_python_lambda(child, source, language, lang_ctx, state, acc)

      java_anonymous_class_body?(language, kind, child) ->
        state = %{state | container_kind: :class_like, class_qname: nil}
        walk(child, source, language, lang_ctx, state, acc)

      true ->
        walk(child, source, language, lang_ctx, state, acc)
    end
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
    walk_nodes(List.wrap(body), source, language, lang_ctx, %{state | class_qname: nil}, acc)
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

    name =
      case type_name && TS.node_child_by_field_name(child, "trait") do
        nil ->
          type_name

        trait_node ->
          case rust_trait_name(trait_node, source) do
            nil -> type_name
            trait_name -> type_name <> "." <> trait_name
          end
      end

    # Trait-qualified scope names the definitions, but `self.x()` resolves to
    # the impl's TYPE, where the inherent members live.
    state = %{state | self_name: type_name}
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
           else: {%{state | self_name: receiver}, receiver <> "." <> name}

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
        if object && TS.node_kind(object) != "self", do: %{state | class_qname: nil}, else: state

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
         %{container_kind: :function_like, class_qname: class_qname} = state,
         acc
       )
       when is_binary(class_qname) do
    name = name_field(child, language, kind, source)
    state = %{state | scope: String.split(class_qname, ".")}
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

  # Scope/qname/class_qname threading, identical once `category` and `name`
  # are known regardless of how they were derived.
  defp handle_definition_category(child, category, name, source, language, lang_ctx, state, acc) do
    {new_scope, new_enclosing_qname, new_class_qname, acc} =
      case name do
        nil ->
          {state.scope, state.enclosing_qname, state.class_qname, acc}

        _ ->
          qname = Enum.join(state.scope ++ [name], ".")
          entity_kind = entity_kind_for(category, state.container_kind)
          entity = %{qualified_name: qname, kind: entity_kind, line: line(child)}

          class_qname =
            if receiver_owner?(category, state.self_name),
              do: Enum.join(state.scope ++ [state.self_name || name], "."),
              else: state.class_qname

          {state.scope ++ [name], qname, class_qname, add_entity(acc, entity)}
      end

    {new_class_qname, pending_class} =
      python_class_receiver(language, category, state, new_class_qname)

    if at_cap?(acc) do
      acc
    else
      new_state = %{
        scope: new_scope,
        mod_scope: next_mod_scope(state.mod_scope, language, category, name),
        container_kind: category,
        enclosing_qname: new_enclosing_qname,
        class_qname:
          if(receiver_boundary?(child, source, language, category, name, state),
            do: nil,
            else: new_class_qname
          ),
        pending_class: pending_class,
        self_name: nil
      }

      walk_definition(child, category, language, source, lang_ctx, state, new_state, acc)
    end
  end

  # A class heritage (`extends <expr>`) is evaluated in the ENCLOSING scope.
  defp walk_js_class(node, source, language, lang_ctx, outer_state, inner_state, acc) do
    Enum.reduce_while(named_children(node), acc, fn child, acc ->
      state = if TS.node_kind(child) == "class_heritage", do: outer_state, else: inner_state

      if at_cap?(acc),
        do: {:halt, acc},
        else: {:cont, process_child(child, source, language, lang_ctx, state, acc)}
    end)
  end

  # Entering a python class does not bind `self`: its direct statements keep the
  # outer receiver and only functions defined directly in the body get the
  # class (held in `pending_class` meanwhile) as theirs.
  defp python_class_receiver("python", :class_like, state, class_qname),
    do: {state.class_qname, class_qname}

  defp python_class_receiver("python", :function_like, %{container_kind: :class_like} = state, _) do
    {state.pending_class || state.class_qname, nil}
  end

  defp python_class_receiver(_language, _category, _state, class_qname), do: {class_qname, nil}

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

  defp receiver_owner?(category, _self_name) when category in [:class_like, :module_like],
    do: true

  defp receiver_owner?(:method_like, self_name), do: not is_nil(self_name)
  defp receiver_owner?(_category, _self_name), do: false

  defp next_mod_scope(mod_scope, "rust", :module_like, name) when is_binary(name),
    do: mod_scope ++ [name]

  defp next_mod_scope(mod_scope, _language, _category, _name), do: mod_scope

  # Definitions that bind their own `this`, or (unnamed classes) have no graph
  # identity to resolve a receiver to.
  defp receiver_boundary?(node, source, language, category, name, state) do
    this_rebinding?(language, TS.node_kind(node)) or object_literal_method?(node) or
      (is_nil(name) and category == :class_like) or
      python_rebinds_self?(node, source, language, state)
  end

  # A python function nested in a function (not a direct method) that takes its
  # own `self` parameter shadows the outer receiver.
  defp python_rebinds_self?(node, source, "python", %{container_kind: container})
       when container != :class_like do
    case TS.node_child_by_field_name(node, "parameters") do
      nil -> false
      params -> params |> named_children() |> Enum.any?(&self_param?(&1, source))
    end
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

  # Walks the whole definition node: these grammars give the parameter list its
  # own dedicated node kind, so there's no ambiguity to worry about.
  defp walk_definition(node, _category, lang, source, lang_ctx, _outer, inner, acc),
    do: walk(node, source, lang, lang_ctx, inner, acc)

  defp entity_kind_for(:class_like, _container), do: :class
  defp entity_kind_for(:module_like, _container), do: :module
  defp entity_kind_for(:method_like, _container), do: :method
  defp entity_kind_for(:function_like, :class_like), do: :method
  defp entity_kind_for(:function_like, _container), do: :function

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
              name: scoped_callee_name(name, self_receiver?, state.class_qname),
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
  defp scoped_callee_name(name, true, class_qname) when is_binary(class_qname),
    do: class_qname <> "." <> name

  defp scoped_callee_name(name, _self_receiver?, _class_qname), do: name

  defp callee_name(call_node, source, "python") do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node) do
      qualified_or_bare(fn_node, source, "attribute", "object", "attribute", &python_self?/2)
    end
  end

  defp callee_name(call_node, source, lang) when lang in ["javascript", "typescript"] do
    with fn_node when not is_nil(fn_node) <- callee_node(call_node) do
      qualified_or_bare(fn_node, source, "member_expression", "object", "property", &this_node?/2)
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
      if TS.node_kind(fn_node) == "field_expression" do
        rust_field_expression_callee(fn_node, source)
      else
        {fallback_last_segment(source, fn_node), false}
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
      {slice(source, fn_node), false}
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
        module_ref = {strip_quotes(slice(source, src_node)), ln}
        [module_ref | js_import_symbol_refs(node, source, ln)]
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
        [{slice(source, child), ln}]

      "named_imports" ->
        child
        |> named_children()
        |> Enum.filter(&(TS.node_kind(&1) == "import_specifier"))
        |> Enum.flat_map(&import_specifier_ref(&1, source, ln))

      _ ->
        []
    end
  end

  defp import_specifier_ref(spec, source, ln) do
    case TS.node_child_by_field_name(spec, "name") do
      nil -> []
      name_node -> [{slice(source, name_node), ln}]
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
      type_node -> source |> slice(rust_base_type_node(type_node)) |> rust_dotted()
    end
  end

  defp name_field(node, _language, _kind, source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> nil
      name_node -> definition_name_text(name_node, source)
    end
  end

  # js/ts allow string-literal method names (`"helper"() {}`).
  defp definition_name_text(name_node, source) do
    if TS.node_kind(name_node) == "string",
      do: string_content(name_node, source),
      else: slice(source, name_node)
  end

  defp rust_dotted(path),
    do:
      path
      |> String.split("::")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(".")

  defp ruby_dotted(name), do: name |> String.split("::") |> Enum.map_join(".", &String.trim/1)

  # `Foo<T>` -> `Foo`: type arguments are not part of a symbol's identity.
  defp rust_base_type_node(type_node) do
    with "generic_type" <- TS.node_kind(type_node),
         inner when not is_nil(inner) <- TS.node_child_by_field_name(type_node, "type") do
      inner
    else
      _ -> type_node
    end
  end

  defp line(node), do: TS.node_start_position(node).row + 1

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    end_byte = TS.node_end_byte(node)
    if end_byte > start_byte, do: binary_part(source, start_byte, end_byte - start_byte), else: ""
  end

  defp at_cap?(acc), do: acc.count >= @max_items

  # Oversized symbols are skipped at the single choke point both emission
  # paths go through (see @max_symbol_bytes). A skipped definition still
  # extends the scope for its children, whose qualified names then exceed the
  # cap too and are skipped consistently.
  defp add_entity(acc, %{qualified_name: qname}) when byte_size(qname) > @max_symbol_bytes,
    do: acc

  defp add_entity(acc, entity),
    do: %{acc | entities: [entity | acc.entities], count: acc.count + 1}

  defp add_reference(acc, %{name: name}) when byte_size(name) > @max_symbol_bytes,
    do: acc

  defp add_reference(acc, reference),
    do: %{acc | references: [reference | acc.references], count: acc.count + 1}
end
