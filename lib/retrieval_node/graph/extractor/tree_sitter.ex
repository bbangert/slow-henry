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
  # which would discard the whole UpsertChunks job. Skipped, not truncated —
  # truncation would collide unrelated junk under one entity.
  @max_symbol_bytes 256

  # Node kind -> definition category, per language. Anything not listed here
  # is not a definition node. Category feeds `entity_kind_for/2`:
  #   :class_like  -> :class
  #   :module_like -> :module
  #   :function_like -> :function, UNLESS the immediately-enclosing container
  #                      is :class_like -> :method
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

  @impl true
  def extract({root, source}, language, _opts) do
    def_kinds = Map.get(@definition_kinds, language, %{})
    call_kind = Map.get(@call_kinds, language)
    import_kinds = Map.get(@import_kinds, language, [])
    lang_ctx = %{def_kinds: def_kinds, call_kind: call_kind, import_kinds: import_kinds}

    state = %{scope: [], container_kind: nil, enclosing_qname: nil}
    acc = %{entities: [], references: [], count: 0}

    acc = walk(root, source, language, lang_ctx, state, acc)

    {:ok, %{entities: Enum.reverse(acc.entities), references: Enum.reverse(acc.references)}}
  end

  defp walk(node, source, language, lang_ctx, state, acc) do
    node
    |> named_children()
    |> Enum.reduce_while(acc, fn child, acc ->
      if at_cap?(acc) do
        {:halt, acc}
      else
        {:cont, process_child(child, source, language, lang_ctx, state, acc)}
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

      true ->
        walk(child, source, language, lang_ctx, state, acc)
    end
  end

  defp maybe_walk(acc, child, source, language, lang_ctx, state) do
    if at_cap?(acc), do: acc, else: walk(child, source, language, lang_ctx, state, acc)
  end

  # --- definitions -----------------------------------------------------

  defp handle_definition(child, kind, source, language, lang_ctx, state, acc) do
    category = Map.fetch!(lang_ctx.def_kinds, kind)
    name = name_field(child, language, kind, source)

    {new_scope, new_enclosing_qname, acc} =
      case name do
        nil ->
          {state.scope, state.enclosing_qname, acc}

        _ ->
          qname = Enum.join(state.scope ++ [name], ".")
          entity_kind = entity_kind_for(category, state.container_kind)
          entity = %{qualified_name: qname, kind: entity_kind, line: line(child)}
          {state.scope ++ [name], qname, add_entity(acc, entity)}
      end

    if at_cap?(acc) do
      acc
    else
      new_state = %{
        scope: new_scope,
        container_kind: category,
        enclosing_qname: new_enclosing_qname
      }

      walk(child, source, language, lang_ctx, new_state, acc)
    end
  end

  defp entity_kind_for(:class_like, _container), do: :class
  defp entity_kind_for(:module_like, _container), do: :module
  defp entity_kind_for(:function_like, :class_like), do: :method
  defp entity_kind_for(:function_like, _container), do: :function

  # --- calls -------------------------------------------------------------

  defp handle_call(child, source, language, state, acc) do
    case callee_name(child, source, language) do
      nil ->
        acc

      name ->
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
              name: name,
              kind: :call,
              from: state.enclosing_qname,
              line: line(child)
            })
        end
    end
  end

  defp callee_name(call_node, source, "python") do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      qualified_or_bare(fn_node, source, "attribute", "attribute")
    end
  end

  defp callee_name(call_node, source, lang) when lang in ["javascript", "typescript"] do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      qualified_or_bare(fn_node, source, "member_expression", "property")
    end
  end

  defp callee_name(call_node, source, "go") do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      qualified_or_bare(fn_node, source, "selector_expression", "field")
    end
  end

  defp callee_name(call_node, source, "rust") do
    with fn_node when not is_nil(fn_node) <- TS.node_child_by_field_name(call_node, "function") do
      fallback_last_segment(source, fn_node)
    end
  end

  defp callee_name(call_node, source, "ruby") do
    with m_node when not is_nil(m_node) <- TS.node_child_by_field_name(call_node, "method") do
      slice(source, m_node)
    end
  end

  defp callee_name(call_node, source, "java") do
    with n_node when not is_nil(n_node) <- TS.node_child_by_field_name(call_node, "name") do
      slice(source, n_node)
    end
  end

  defp callee_name(_call_node, _source, _language), do: nil

  # Shared shape for the three qualified-callee grammars (python `attribute`,
  # js/ts `member_expression`, go `selector_expression`): if the callee subtree
  # is the qualified wrapper kind, resolve its rightmost field; otherwise it's
  # already a bare identifier, sliced directly.
  defp qualified_or_bare(fn_node, source, wrapper_kind, field_name) do
    if TS.node_kind(fn_node) == wrapper_kind do
      case TS.node_child_by_field_name(fn_node, field_name) do
        nil -> fallback_last_segment(source, fn_node)
        field_node -> slice(source, field_node)
      end
    else
      slice(source, fn_node)
    end
  end

  # Defensive fallback for the qualified-callee shapes: slice the whole callee
  # subtree and take the last `.`/`::`-separated segment. Also handles the
  # plain-identifier case (no separator -> the whole text is the segment), so
  # rust's `function:` field can share this single implementation.
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
          nil -> []
          mod_node -> [{slice(source, mod_node), line(mod_node)}]
        end

      _ ->
        []
    end
  end

  defp import_refs(node, source, lang) when lang in ["javascript", "typescript"] do
    case TS.node_child_by_field_name(node, "source") do
      nil -> []
      src_node -> [{strip_quotes(slice(source, src_node)), line(node)}]
    end
  end

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

  defp import_refs(node, source, "rust") do
    case TS.node_child_by_field_name(node, "argument") do
      nil -> []
      arg_node -> [{slice(source, arg_node), line(node)}]
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

  defp python_import_name(n, source) do
    case TS.node_kind(n) do
      "aliased_import" ->
        case TS.node_child_by_field_name(n, "name") do
          nil -> {slice(source, n), line(n)}
          name_node -> {slice(source, name_node), line(n)}
        end

      _ ->
        {slice(source, n), line(n)}
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

  # Go's `type_declaration` (the chunk-boundary kind wrapping struct/interface/
  # alias decls) has no "name" field of its own — empirically the name lives
  # one level down, on its `type_spec` child. Rust's `impl_item` likewise has
  # no "name" field; the closest analog is the "type" field (the type being
  # impl'd). Every other definition kind exposes "name" directly.
  defp name_field(node, "go", "type_declaration", source) do
    case Enum.find(named_children(node), &(TS.node_kind(&1) == "type_spec")) do
      nil -> nil
      spec -> name_field(spec, "go", "type_spec", source)
    end
  end

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
