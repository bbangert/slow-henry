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
      "class_declaration" => :class_like
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
      "class_declaration" => :class_like,
      "interface_declaration" => :class_like,
      "type_alias_declaration" => :class_like,
      "enum_declaration" => :class_like
    },
    "go" => %{
      "function_declaration" => :function_like,
      "method_declaration" => :function_like,
      "type_declaration" => :class_like
    },
    "rust" => %{
      "function_item" => :function_like,
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

  # Elixir's grammar gives every construct the SAME node kind ("call",
  # discriminated by its `target:` field's identifier text) — the kind-keyed
  # tables above can't express that, so elixir is dispatched through its own
  # process_child/6 clause (handle_elixir_call/6 and friends) instead of
  # gaining entries here. defmodule/defprotocol/defimpl are :module_like
  # containers; the def-family are :function_like (entity_kind_for/2 already
  # turns :function_like nested in a :module_like container into :function —
  # same rule that gives rust's mod_item-nested functions :function, not
  # :method). alias/import/use/require are the import forms.
  #
  # defimpl is named differently from defmodule/defprotocol (see
  # handle_elixir_definition/7's dedicated "defimpl" clause and
  # elixir_defimpl_names/3): its real generated module name is
  # `<Protocol>.<ForType>` (Elixir protocol semantics), not the protocol name
  # alone — reusing the plain protocol naming that defmodule/defprotocol get
  # would make every defimpl of the same protocol, and the defprotocol
  # itself, collapse onto one shared "Sized" entity. `for: [A, B]` names MORE
  # than one type at once — Elixir generates one full implementation per
  # listed type — so elixir_defimpl_names/3 returns one `<Protocol>.<ForType>`
  # per listed alias, and the "defimpl" clause below walks the impl body once
  # per name.
  @elixir_module_forms ~w(defmodule defprotocol defimpl)
  @elixir_function_forms ~w(def defp defmacro defmacrop defguard defguardp)
  @elixir_def_forms @elixir_module_forms ++ @elixir_function_forms
  @elixir_import_forms ~w(alias import use require)

  # Typespec attributes are the type language, not runtime code: `@spec
  # f(binary()) :: :ok` writes `f` and `binary` in call syntax, but neither is
  # a call -- they're a function signature. Unlike other attribute values
  # (walked below so a real call like `@x String.trim(y)` is still found),
  # these are never descended into at all.
  @elixir_typespec_attrs ~w(spec callback macrocallback type typep opaque)

  @impl true
  def extract({root, source}, language, _opts) do
    def_kinds = Map.get(@definition_kinds, language, %{})
    call_kind = Map.get(@call_kinds, language)
    import_kinds = Map.get(@import_kinds, language, [])
    lang_ctx = %{def_kinds: def_kinds, call_kind: call_kind, import_kinds: import_kinds}

    state = %{scope: [], container_kind: nil, enclosing_qname: nil, class_qname: nil}
    acc = %{entities: [], references: [], count: 0}

    acc = walk(root, source, language, lang_ctx, state, acc)

    {:ok, %{entities: Enum.reverse(acc.entities), references: Enum.reverse(acc.references)}}
  end

  defp walk(node, source, language, lang_ctx, state, acc) do
    walk_nodes(named_children(node), source, language, lang_ctx, state, acc)
  end

  # Like walk/6, but over an explicit node list instead of a parent's named
  # children — used where the nodes to descend into are picked out by hand
  # (see walk_elixir_keywords_values/6) rather than being "every named child
  # of this node".
  defp walk_nodes(nodes, source, language, lang_ctx, state, acc) do
    Enum.reduce_while(nodes, acc, fn node, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont, process_child(node, source, language, lang_ctx, state, acc)}
      end
    end)
  end

  # Elixir has no kind-keyed table to dispatch through (see @elixir_def_forms
  # above) — every node worth inspecting is a "call", discriminated by its
  # target text, so it gets its own clause ahead of the generic one below.
  defp process_child(child, source, "elixir" = language, lang_ctx, state, acc) do
    if TS.node_kind(child) == "call" do
      handle_elixir_call(child, source, language, lang_ctx, state, acc)
    else
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

      true ->
        walk(child, source, language, lang_ctx, state, acc)
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
    |> Enum.filter(&(TS.node_kind(&1) == "type_spec"))
    |> Enum.reduce_while(acc, fn spec, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        name = name_field(spec, language, "type_spec", source)

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
    type_name = name_field(child, language, kind, source)

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

    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  defp handle_definition(child, kind, source, language, lang_ctx, state, acc) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)
    name = name_field(child, language, kind, source)
    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

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

  # Shared by the kind-table-driven languages (handle_definition/7 above) and
  # elixir's predicate-driven handle_elixir_definition/6 below — the
  # scope/qname/class_qname threading is identical once `category` and `name`
  # are known, regardless of how they were derived.
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
            if category in [:class_like, :module_like], do: qname, else: state.class_qname

          {state.scope ++ [name], qname, class_qname, add_entity(acc, entity)}
      end

    if at_cap?(acc) do
      acc
    else
      new_state = %{
        scope: new_scope,
        container_kind: category,
        enclosing_qname: new_enclosing_qname,
        class_qname: new_class_qname
      }

      walk_definition_body(child, category, language, source, lang_ctx, new_state, acc)
    end
  end

  # An elixir def's head (`process(order)`, or the `when`-guard wrapping it —
  # see the dump in handle_elixir_definition/6's neighborhood) parses as an
  # ordinary nested `call`/`binary_operator`, indistinguishable by shape from
  # a real call site (handle_elixir_call/6 dispatches on shape alone) —
  # walking the whole definition node verbatim, as every other language does,
  # would turn every def into a spurious self-call to its own name. So
  # elixir's def-family (:function_like; :module_like — defmodule et al —
  # still falls through to the generic clause below, since its head is a
  # plain `alias`, not a call) walks only the body instead: the `do_block`,
  # or (keyword form, `def f(x), do: expr`) the `keywords` pair's value.
  # `when`-guard expressions (`when is_binary(x)`) are deliberately skipped
  # too, even though they're arguably real references, for consistency with
  # the head skip — both live in the same `arguments` node the walk below
  # ignores except for `keywords`. Default-arg expressions
  # (`def f(x \\ default())`) are skipped as well: the arguments node mixes
  # them with the head call with no cheap way to tell them apart.
  defp walk_definition_body(
         child,
         :function_like,
         "elixir" = language,
         source,
         lang_ctx,
         state,
         acc
       ) do
    child
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) in ["do_block", "arguments"]))
    |> Enum.reduce_while(acc, fn node, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont, walk_elixir_def_body_node(node, source, language, lang_ctx, state, acc)}
      end
    end)
  end

  # Every kind-table-driven language (and elixir's :module_like) walks the
  # whole definition node as before: their grammars give the parameter list
  # its own dedicated node kind, so there's no ambiguity to worry about
  # there.
  defp walk_definition_body(child, _category, language, source, lang_ctx, state, acc) do
    walk(child, source, language, lang_ctx, state, acc)
  end

  defp walk_elixir_def_body_node(node, source, language, lang_ctx, state, acc) do
    case TS.node_kind(node) do
      "do_block" ->
        walk(node, source, language, lang_ctx, state, acc)

      "arguments" ->
        node
        |> named_children()
        |> Enum.find(&(TS.node_kind(&1) == "keywords"))
        |> case do
          nil ->
            acc

          keywords_node ->
            walk_elixir_keywords_values(keywords_node, source, language, lang_ctx, state, acc)
        end
    end
  end

  # `keywords` holds one `pair` per `key: value` entry (just `do:` for defs
  # in practice) — walk each pair's `value` as an ordinary node (not its
  # whole `pair`, whose `key` is a `keyword` leaf with nothing to walk
  # anyway) so a value that is itself a call (`do: helper(order)`) is
  # recognized as one via process_child/6, same as any other call site.
  defp walk_elixir_keywords_values(keywords_node, source, language, lang_ctx, state, acc) do
    keywords_node
    |> named_children()
    |> Enum.flat_map(fn pair ->
      case TS.node_child_by_field_name(pair, "value") do
        nil -> []
        value_node -> [value_node]
      end
    end)
    |> walk_nodes(source, language, lang_ctx, state, acc)
  end

  defp entity_kind_for(:class_like, _container), do: :class
  defp entity_kind_for(:module_like, _container), do: :module
  defp entity_kind_for(:method_like, _container), do: :method
  defp entity_kind_for(:function_like, :class_like), do: :method
  defp entity_kind_for(:function_like, _container), do: :function

  # --- elixir --------------------------------------------------------------
  #
  # Every elixir construct parses as a `call` node (target: identifier), so
  # there's no kind to key a table on — this dispatches by the target text
  # instead, one predicate check at a time: def-form -> definition,
  # alias/import/use/require -> import ref, a typespec attribute
  # (@elixir_typespec_attrs) -> skip entirely (its value is the type
  # language, not calls), any other `@attr` name-call -> skip the name-call
  # itself but still descend for calls nested in the attribute's value, else
  # a real call reference (bare identifier or dot-qualified).

  defp handle_elixir_call(call_node, source, language, lang_ctx, state, acc) do
    target_node = TS.node_child_by_field_name(call_node, "target")
    target_identifier = elixir_target_identifier(target_node, source)

    cond do
      is_nil(target_node) ->
        walk(call_node, source, language, lang_ctx, state, acc)

      target_identifier in @elixir_def_forms ->
        handle_elixir_definition(
          call_node,
          target_identifier,
          source,
          language,
          lang_ctx,
          state,
          acc
        )

      target_identifier in @elixir_import_forms ->
        handle_elixir_import(call_node, source, state, acc)

      target_identifier in @elixir_typespec_attrs and
          elixir_attribute_name_call?(call_node, source) ->
        acc

      elixir_attribute_name_call?(call_node, source) ->
        walk(call_node, source, language, lang_ctx, state, acc)

      true ->
        acc
        |> handle_elixir_call_ref(call_node, target_node, source, state)
        |> maybe_walk(call_node, source, language, lang_ctx, state)
    end
  end

  defp elixir_target_identifier(nil, _source), do: nil

  defp elixir_target_identifier(target_node, source) do
    if TS.node_kind(target_node) == "identifier", do: slice(source, target_node), else: nil
  end

  # `@moduledoc "x"` / `@x String.trim(y)` both parse as
  # `unary_operator(operator: "@", operand: call(target: identifier ...))` —
  # the attribute-NAME call itself (target "moduledoc"/"x") is noise, not a
  # real callee, but is indistinguishable from a real call by target alone.
  # `node_parent` + the unary_operator's own `operator:` field (not just its
  # kind, which every unary op — `!`, `not`, `-` — also produces) is what
  # actually identifies it.
  defp elixir_attribute_name_call?(call_node, source) do
    case TS.node_parent(call_node) do
      nil ->
        false

      parent ->
        TS.node_kind(parent) == "unary_operator" and
          case TS.node_child_by_field_name(parent, "operator") do
            nil -> false
            op_node -> slice(source, op_node) == "@"
          end
    end
  end

  # defimpl's generated module name (`<Protocol>.<ForType>`, or
  # `<Protocol>.<EnclosingModule>` for the implicit-for nested form) is
  # ABSOLUTE — Elixir does not prefix it by whatever module it happens to be
  # lexically written inside, unlike every other definition form below
  # (defmodule/defprotocol/def/etc, which nest normally under
  # `state.scope`). Scope is reset to [] for every pass below so
  # handle_definition_category's `state.scope ++ [name]` join doesn't
  # double-prepend the enclosing module on top of itself — it's already
  # folded into `name` via elixir_defimpl_names/3's `state.class_qname`
  # fallback for the no-`for:` case.
  #
  # `for: [A, B]` generates one full implementation PER listed type — real
  # Elixir semantics, not a fanout approximation — so
  # elixir_defimpl_names/3 returns one qualified name per target and this
  # walks `child`'s body once per name, threading `acc` through so each pass
  # sees the entities/references the previous pass already collected. Each
  # pass is independent (same defimpl body, different `<Protocol>.<ForType>`
  # scope), so `Sized.BitString.size` and `Sized.Map.size` both end up
  # holding their own copy of whatever the shared body defines/references,
  # same as if the two impls had been written out separately. The cap check
  # before each pass (mirroring walk_nodes/6's own check before
  # process_child/6) is what stops the fanout once @max_items is reached,
  # instead of unconditionally emitting one more full body walk per
  # remaining listed type. A single-alias `for:`, or no `for:` at all, always
  # resolves to exactly one name, so this loop runs its body exactly once —
  # unchanged behavior for those cases.
  defp handle_elixir_definition(
         child,
         "defimpl" = _target_text,
         source,
         language,
         lang_ctx,
         state,
         acc
       ) do
    defimpl_state = %{state | scope: []}

    case elixir_defimpl_names(child, state, source) do
      [] ->
        # Neither a protocol name nor a for:/class_qname target could be
        # resolved (e.g. malformed arguments) — still walk the body once,
        # unscoped, same as handle_definition_category's own nil-name branch
        # does for every other definition kind, instead of silently dropping
        # whatever the body contains.
        handle_definition_category(
          child,
          :module_like,
          nil,
          source,
          language,
          lang_ctx,
          defimpl_state,
          acc
        )

      names ->
        walk_defimpl_names(names, child, source, language, lang_ctx, defimpl_state, acc)
    end
  end

  defp handle_elixir_definition(child, target_text, source, language, lang_ctx, state, acc) do
    category = if target_text in @elixir_module_forms, do: :module_like, else: :function_like
    name = elixir_definition_name(child, category, source)
    handle_definition_category(child, category, name, source, language, lang_ctx, state, acc)
  end

  # One handle_definition_category/8 pass per name in `names` — see the
  # "defimpl" clause of handle_elixir_definition/7 above for why there can be
  # more than one. The at_cap? check before each pass mirrors walk_nodes/6's
  # own check before process_child/6, and is what stops the fanout once
  # @max_items is hit.
  defp walk_defimpl_names(names, child, source, language, lang_ctx, defimpl_state, acc) do
    Enum.reduce_while(names, acc, fn name, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont,
         handle_definition_category(
           child,
           :module_like,
           name,
           source,
           language,
           lang_ctx,
           defimpl_state,
           acc
         )}
      end
    end)
  end

  defp elixir_definition_name(call_node, :module_like, source) do
    case elixir_arguments_node(call_node) do
      nil ->
        nil

      args_node ->
        args_node
        |> named_children()
        |> Enum.find(&(TS.node_kind(&1) == "alias"))
        |> case do
          nil -> nil
          alias_node -> slice(source, alias_node)
        end
    end
  end

  defp elixir_definition_name(call_node, :function_like, source) do
    case elixir_arguments_node(call_node) do
      nil ->
        nil

      args_node ->
        case named_children(args_node) do
          [] -> nil
          [first | _] -> elixir_def_name_from(first, source)
        end
    end
  end

  # `defimpl Sized, for: BitString do ... end` -> ["Sized.BitString"], so each
  # implementation's defs get their own qualified namespace instead of
  # colliding with the protocol and with every other impl of it. `for: [A,
  # B]` returns one qualified name PER listed type — `["Sized.A",
  # "Sized.B"]` — since Elixir generates one full implementation per type
  # listed there; the caller (handle_elixir_definition/7's "defimpl" clause)
  # walks the impl body once per returned name.
  # `elixir_definition_name(call_node, :module_like, source)` above already
  # resolves the protocol name (first `alias` in `arguments`) — reused here
  # rather than re-walking the same node. `for:` is found among `keywords`'
  # pairs by its key text (the keyword token's span always starts "for:",
  # regardless of surrounding whitespace — empirically verified). Its value
  # is either a bare `alias` (`for: BitString`, one target) or a `list` of
  # them (`for: [A, B]`, one target per listed alias). No `for:` at all is
  # valid only when defimpl is nested directly inside a defmodule body
  # (Elixir then implicitly targets the enclosing module) — `state.class_qname`
  # (the nearest enclosing class-like/module-like qname, tracked by
  # handle_definition_category/8 on every entry) already names exactly that
  # enclosing module; when unset (e.g. an unsupported/invalid top-level
  # no-`for:` defimpl) this falls back to the bare protocol name rather than
  # crashing. Returns `[]` only when even the protocol name itself can't be
  # resolved (malformed arguments) — the caller still walks the body once,
  # unscoped, in that case.
  defp elixir_defimpl_names(call_node, state, source) do
    with args_node when not is_nil(args_node) <- elixir_arguments_node(call_node),
         protocol_name when not is_nil(protocol_name) <-
           elixir_definition_name(call_node, :module_like, source) do
      elixir_defimpl_target_names(protocol_name, args_node, state.class_qname, source)
    else
      nil -> []
    end
  end

  defp elixir_defimpl_target_names(protocol_name, args_node, class_qname, source) do
    case elixir_defimpl_for_types(args_node, source) do
      [] -> elixir_defimpl_fallback_names(protocol_name, class_qname)
      types -> Enum.map(types, &(protocol_name <> "." <> &1))
    end
  end

  defp elixir_defimpl_fallback_names(protocol_name, nil), do: [protocol_name]
  defp elixir_defimpl_fallback_names(protocol_name, type), do: [protocol_name <> "." <> type]

  defp elixir_defimpl_for_types(args_node, source) do
    args_node
    |> named_children()
    |> Enum.find(&(TS.node_kind(&1) == "keywords"))
    |> case do
      nil ->
        []

      keywords_node ->
        keywords_node
        |> named_children()
        |> Enum.find_value([], &elixir_defimpl_for_pair_values(&1, source))
    end
  end

  defp elixir_defimpl_for_pair_values(pair_node, source) do
    with key_node when not is_nil(key_node) <- TS.node_child_by_field_name(pair_node, "key"),
         true <- String.starts_with?(slice(source, key_node), "for:"),
         value_node when not is_nil(value_node) <- TS.node_child_by_field_name(pair_node, "value") do
      elixir_defimpl_type_names(value_node, source)
    else
      _ -> nil
    end
  end

  # `for: BitString` -> a bare `alias`, one target type: `[name]`. `for: [A,
  # B]` -> a `list` of them, ALL returned (see elixir_defimpl_names/3's
  # comment above for how the caller turns each into its own
  # `<Protocol>.<ForType>` pass instead of collapsing to one).
  defp elixir_defimpl_type_names(value_node, source) do
    case TS.node_kind(value_node) do
      "alias" -> [slice(source, value_node)]
      "list" -> elixir_defimpl_list_alias_names(value_node, source)
      _ -> []
    end
  end

  defp elixir_defimpl_list_alias_names(list_node, source) do
    list_node
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) == "alias"))
    |> Enum.map(&slice(source, &1))
  end

  # `arguments` (like `do_block`) is a plain positional child in this
  # grammar, NOT a `node_child_by_field_name`-reachable field — empirically
  # verified: only `target`/`left`/`right`/`operator`/`operand`/`key`/`value`
  # are real fields here. Find it by kind among the call's named children.
  defp elixir_arguments_node(call_node) do
    call_node
    |> named_children()
    |> Enum.find(&(TS.node_kind(&1) == "arguments"))
  end

  # Three empirically verified name shapes: a bare identifier (zero-arity
  # no-paren def), a nested `call` (the common `def name(...)` case), or a
  # `binary_operator` (a `when`-guard clause) whose `left:` is the name-call.
  defp elixir_def_name_from(node, source) do
    case TS.node_kind(node) do
      "call" ->
        case TS.node_child_by_field_name(node, "target") do
          nil -> nil
          target_node -> slice(source, target_node)
        end

      "identifier" ->
        slice(source, node)

      "binary_operator" ->
        case TS.node_child_by_field_name(node, "left") do
          nil -> nil
          left_node -> elixir_def_name_from(left_node, source)
        end

      _ ->
        nil
    end
  end

  defp handle_elixir_call_ref(acc, call_node, target_node, source, state) do
    case elixir_callee_name(target_node, source) do
      nil ->
        acc

      name ->
        add_reference(acc, %{
          name: name,
          kind: :call,
          from: state.enclosing_qname,
          line: line(call_node)
        })
    end
  end

  # Bare `helper(order)` -> target is a plain identifier, sliced directly.
  # Qualified `B.run(order)` -> target is `dot(left: alias, right:
  # identifier)`, resolved to the rightmost member, same convention as the
  # other qualified-callee languages (no self/this concept in elixir, so no
  # receiver-scoping to do here).
  defp elixir_callee_name(target_node, source) do
    case TS.node_kind(target_node) do
      "identifier" ->
        slice(source, target_node)

      "dot" ->
        case TS.node_child_by_field_name(target_node, "right") do
          nil -> nil
          right_node -> slice(source, right_node)
        end

      _ ->
        nil
    end
  end

  # alias/import/use/require all resolve to a single :import ref named by the
  # alias argument's source text (the alias node's text IS the full dotted
  # module name, e.g. "Foo.Bar" — one leaf token in this grammar, not nested
  # segments). `alias Foo.{Bar, Baz}` parses its argument as
  # `dot(left: alias "Foo", right: tuple(...))` instead of a plain `alias`
  # node — best-effort here is a single "Foo" ref rather than resolving each
  # brace member.
  defp handle_elixir_import(call_node, source, state, acc) do
    case elixir_arguments_node(call_node) do
      nil ->
        acc

      args_node ->
        case elixir_import_symbol(args_node, source) do
          nil ->
            acc

          name ->
            add_reference(acc, %{
              name: name,
              kind: :import,
              from: state.enclosing_qname,
              line: line(call_node)
            })
        end
    end
  end

  defp elixir_import_symbol(args_node, source) do
    args_node
    |> named_children()
    |> Enum.find_value(fn child ->
      case TS.node_kind(child) do
        "alias" -> slice(source, child)
        "dot" -> elixir_alias_dot_name(child, source)
        _ -> nil
      end
    end)
  end

  defp elixir_alias_dot_name(dot_node, source) do
    case TS.node_child_by_field_name(dot_node, "left") do
      nil -> nil
      left_node -> if TS.node_kind(left_node) == "alias", do: slice(source, left_node), else: nil
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
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      qualified_or_bare(fn_node, source, "attribute", "object", "attribute", &python_self?/2)
    end
  end

  defp callee_name(call_node, source, lang) when lang in ["javascript", "typescript"] do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      qualified_or_bare(fn_node, source, "member_expression", "object", "property", &this_node?/2)
    end
  end

  defp callee_name(call_node, source, "go") do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      # Go has no `self`/`this` keyword (receivers are user-named), so the
      # object side is never scope-resolvable here.
      qualified_or_bare(fn_node, source, "selector_expression", "operand", "field", fn _, _ ->
        false
      end)
    end
  end

  defp callee_name(call_node, source, "rust") do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
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
    case first_string_arg(call_node, source) do
      nil -> :not_import
      str -> {:import, str}
    end
  end

  defp ruby_import(_call_node, _source, _language, _name), do: :not_import

  defp first_string_arg(call_node, source) do
    with args_node when not is_nil(args_node) <-
           TS.node_child_by_field_name(call_node, "arguments"),
         [str_node | _] <- Enum.filter(named_children(args_node), &(TS.node_kind(&1) == "string")) do
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
    node |> named_children() |> Enum.flat_map(&rust_use_paths(&1, prefix, source))
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

  defp strip_quotes(text), do: text |> String.trim() |> String.trim("\"") |> String.trim("'")

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
      type_node -> slice(source, type_node)
    end
  end

  defp name_field(node, _language, _kind, source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> nil
      name_node -> slice(source, name_node)
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
