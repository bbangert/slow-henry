defmodule RetrievalNode.Chunking.BindingNames do
  @moduledoc """
  The names BOUND by top-level code in one scope (the file root, or a
  container's body), read from the AST — the single rule set behind the
  `names` field on `kind: "toplevel"` chunks.

  `collect/3` walks the direct children of a scope node, descending only
  through the per-language wrapper kinds (`export_statement`,
  `expression_statement`, a class's body node, ...), never into a definition
  or an expression: a `const` inside an arrow function passed to a call is not
  a top-level binding. It returns `{byte, name}` pairs in source order, `byte`
  being the start of the node that carries the name, so the chunker can hand
  each name to the gap piece containing it.

  Per language:

    * python: assignment / augmented / annotated left side — plain
      identifiers and the identifiers of tuple/list targets; attribute and
      subscript targets are skipped; `a = b = 1` yields both
    * javascript/typescript: `const`/`let`/`var` declarators — an identifier
      name, or the bound identifiers of a destructuring pattern (the local
      binding, i.e. the value of `{a: b}`); `customElements.define("x", ..)`
      yields `customElements:x`
    * go: `var`/`const` spec names, grouped or not
    * rust: `const`/`static` items
    * ruby: assignment to a constant (plain or multiple)
    * java: field declarators
    * elixir: module attributes `@name [value]`, except documentation / typing
      / compiler-directive attributes (`@excluded_elixir_attrs`)
  """

  alias TreeSitterLanguagePack, as: TS

  @excluded_elixir_attrs ~w(moduledoc doc spec type typep opaque callback macrocallback impl
                            behaviour derive typedoc compile dialyzer)

  @wrappers %{
    "python" => ~w(expression_statement block),
    "javascript" => ~w(export_statement expression_statement),
    "typescript" => ~w(export_statement expression_statement ambient_declaration),
    "go" => ~w(),
    "rust" => ~w(declaration_list),
    "ruby" => ~w(body_statement),
    "java" => ~w(class_body interface_body annotation_type_body enum_body enum_body_declarations),
    "elixir" => ~w(do_block)
  }

  @type entry :: {non_neg_integer(), String.t()}
  @typedoc "Entries sorted by byte, as a tuple for O(log n) positioning."
  @type index :: tuple()

  @doc """
  Binding names of `scope`'s direct top-level statements, in source order, as
  an index for `names_in/4`.
  """
  @spec collect(term(), binary(), String.t()) :: index()
  def collect(scope, source, language) do
    wrappers = Map.get(@wrappers, language, [])

    scope
    |> walk(source, language, wrappers)
    |> Enum.sort_by(&elem(&1, 0))
    |> List.to_tuple()
  end

  @doc """
  The deduped, capped names of the index entries whose byte lies in
  `[from, to)`. Binary-searches the first candidate, then reads forward only
  until `to` or `cap` distinct names — O(log n + names taken) per piece.
  """
  @spec names_in(index(), non_neg_integer(), non_neg_integer(), pos_integer()) :: [String.t()]
  def names_in(index, from, to, cap) do
    index |> first_at_or_after(from, 0, tuple_size(index)) |> take_names(index, to, cap, [])
  end

  defp first_at_or_after(_index, _from, lo, hi) when lo >= hi, do: lo

  defp first_at_or_after(index, from, lo, hi) do
    mid = div(lo + hi, 2)

    if index |> elem(mid) |> elem(0) < from,
      do: first_at_or_after(index, from, mid + 1, hi),
      else: first_at_or_after(index, from, lo, mid)
  end

  defp take_names(i, index, _to, _cap, acc) when i >= tuple_size(index), do: Enum.reverse(acc)

  defp take_names(i, index, to, cap, acc) do
    {byte, name} = elem(index, i)

    cond do
      byte >= to -> Enum.reverse(acc)
      length(acc) >= cap -> Enum.reverse(acc)
      name in acc -> take_names(i + 1, index, to, cap, acc)
      true -> take_names(i + 1, index, to, cap, [name | acc])
    end
  end

  @doc """
  Direct named children of `node`, in one O(n) cursor pass. The indexed
  `node_named_child/2` accessor rescans from the first child on each call.
  """
  @spec named_children(term()) :: [term()]
  def named_children(node) do
    cursor = TS.node_walk(node)

    if TS.treecursor_goto_first_child(cursor), do: collect_siblings(cursor, []), else: []
  end

  defp collect_siblings(cursor, acc) do
    node = TS.treecursor_node(cursor)
    acc = if TS.node_is_named(node), do: [node | acc], else: acc

    if TS.treecursor_goto_next_sibling(cursor),
      do: collect_siblings(cursor, acc),
      else: Enum.reverse(acc)
  end

  defp walk(node, source, language, wrappers) do
    node
    |> named_children()
    |> Enum.flat_map(fn child ->
      kind = TS.node_kind(child)

      if kind in wrappers do
        walk(child, source, language, wrappers)
      else
        bindings(language, kind, child, source)
      end
    end)
  end

  # --- python ---

  defp bindings("python", kind, node, source) when kind in ~w(assignment augmented_assignment),
    do: python_assignment(node, source)

  defp bindings("python", "type_alias_statement", node, source) do
    case named_children(node) do
      [alias_name | _] -> python_targets_of_type(alias_name, source)
      _ -> []
    end
  end

  # --- javascript / typescript ---
  #
  # `const a = b = 1` binds only `a`: `b` is an assignment to an existing
  # variable, not a declaration, so the chain is deliberately not followed.

  defp bindings(lang, kind, node, source)
       when lang in ~w(javascript typescript) and
              kind in ~w(lexical_declaration variable_declaration) do
    node
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) == "variable_declarator"))
    |> Enum.flat_map(fn declarator ->
      case TS.node_child_by_field_name(declarator, "name") do
        nil -> []
        name -> js_pattern_names(name, source)
      end
    end)
  end

  defp bindings(lang, "call_expression", node, source) when lang in ~w(javascript typescript),
    do: custom_element(node, source)

  # --- go ---

  defp bindings("go", kind, node, source) when kind in ~w(var_declaration const_declaration) do
    node
    |> named_children()
    |> Enum.flat_map(fn child ->
      case TS.node_kind(child) do
        k when k in ~w(var_spec const_spec) -> go_spec_names(child, source)
        "var_spec_list" -> child |> named_children() |> Enum.flat_map(&go_spec_names(&1, source))
        _ -> []
      end
    end)
  end

  # --- rust ---

  defp bindings("rust", kind, node, source) when kind in ~w(const_item static_item type_item),
    do: field_name(node, "name", source)

  # --- ruby ---

  defp bindings("ruby", "assignment", node, source), do: ruby_assignment(node, source)

  defp bindings("ruby", "operator_assignment", node, source) do
    case TS.node_child_by_field_name(node, "left") do
      nil -> []
      left -> ruby_constants(left, source)
    end
  end

  # --- java ---

  defp bindings("java", "enum_constant", node, source), do: field_name(node, "name", source)

  defp bindings("java", kind, node, source)
       when kind in ~w(field_declaration constant_declaration) do
    node
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) == "variable_declarator"))
    |> Enum.flat_map(&field_name(&1, "name", source))
  end

  # --- elixir ---

  defp bindings("elixir", "unary_operator", node, source), do: elixir_attribute(node, source)

  defp bindings(_language, _kind, _node, _source), do: []

  # `a = b = 1` nests the second assignment under `right`.
  defp python_assignment(node, source) do
    left =
      case TS.node_child_by_field_name(node, "left") do
        nil -> []
        left -> python_targets(left, source)
      end

    chained =
      case TS.node_child_by_field_name(node, "right") do
        nil ->
          []

        right ->
          if TS.node_kind(right) == "assignment", do: python_assignment(right, source), else: []
      end

    left ++ chained
  end

  defp python_targets_of_type(type_node, source) do
    type_node |> named_children() |> Enum.flat_map(&python_targets(&1, source))
  end

  defp python_targets(node, source) do
    case TS.node_kind(node) do
      "identifier" ->
        [named(node, source)]

      k when k in ~w(pattern_list tuple_pattern list_pattern list_splat_pattern) ->
        node |> named_children() |> Enum.flat_map(&python_targets(&1, source))

      _ ->
        []
    end
  end

  defp js_pattern_names(node, source) do
    case TS.node_kind(node) do
      k when k in ~w(identifier shorthand_property_identifier_pattern) ->
        [named(node, source)]

      "pair_pattern" ->
        value_names(node, "value", source)

      k when k in ~w(assignment_pattern object_assignment_pattern) ->
        value_names(node, "left", source)

      k when k in ~w(object_pattern array_pattern rest_pattern) ->
        node |> named_children() |> Enum.flat_map(&js_pattern_names(&1, source))

      _ ->
        []
    end
  end

  defp value_names(node, field, source) do
    case TS.node_child_by_field_name(node, field) do
      nil -> []
      child -> js_pattern_names(child, source)
    end
  end

  # `customElements.define("my-el", Cls)` as a statement-level call.
  defp custom_element(node, source) do
    with fun when not is_nil(fun) <- TS.node_child_by_field_name(node, "function"),
         "member_expression" <- TS.node_kind(fun),
         true <-
           identifier_text?(TS.node_child_by_field_name(fun, "object"), source, "customElements"),
         true <- identifier_text?(TS.node_child_by_field_name(fun, "property"), source, "define"),
         args when not is_nil(args) <- TS.node_child_by_field_name(node, "arguments"),
         [first | _] <- args |> named_children() |> Enum.reject(&(TS.node_kind(&1) == "comment")),
         "string" <- TS.node_kind(first),
         [fragment | _] <-
           first |> named_children() |> Enum.filter(&(TS.node_kind(&1) == "string_fragment")) do
      [{TS.node_start_byte(node), "customElements:" <> slice(source, fragment)}]
    else
      _ -> []
    end
  end

  defp identifier_text?(nil, _source, _text), do: false

  defp identifier_text?(node, source, text),
    do: TS.node_kind(node) in ~w(identifier property_identifier) and slice(source, node) == text

  # Spec names are the identifier children (`var c, d = 1, 2`); the type and
  # the value expressions are other kinds.
  defp go_spec_names(spec, source) do
    spec
    |> named_children()
    |> Enum.filter(&(TS.node_kind(&1) == "identifier"))
    |> Enum.map(&named(&1, source))
  end

  # `FOO = BAR = 1` nests the second assignment under `right`; in
  # `A, B = C = 1, 2` it sits inside the right_assignment_list.
  defp ruby_assignment(node, source) do
    left =
      case TS.node_child_by_field_name(node, "left") do
        nil -> []
        left -> ruby_constants(left, source)
      end

    chained =
      case TS.node_child_by_field_name(node, "right") do
        nil -> []
        right -> ruby_chained(right, source)
      end

    left ++ chained
  end

  defp ruby_chained(right, source) do
    case TS.node_kind(right) do
      "assignment" ->
        ruby_assignment(right, source)

      "right_assignment_list" ->
        right
        |> named_children()
        |> Enum.filter(&(TS.node_kind(&1) == "assignment"))
        |> Enum.flat_map(&ruby_assignment(&1, source))

      _ ->
        []
    end
  end

  defp ruby_constants(node, source) do
    case TS.node_kind(node) do
      "constant" ->
        [named(node, source)]

      "left_assignment_list" ->
        node |> named_children() |> Enum.flat_map(&ruby_constants(&1, source))

      _ ->
        []
    end
  end

  defp elixir_attribute(node, source) do
    with op when not is_nil(op) <- TS.node_child_by_field_name(node, "operator"),
         "@" <- slice(source, op),
         operand when not is_nil(operand) <- TS.node_child_by_field_name(node, "operand"),
         name when is_binary(name) <- elixir_attribute_name(operand, source),
         false <- name in @excluded_elixir_attrs do
      [{TS.node_start_byte(node), name}]
    else
      _ -> []
    end
  end

  defp elixir_attribute_name(operand, source) do
    case TS.node_kind(operand) do
      "identifier" ->
        slice(source, operand)

      "call" ->
        call_target_name(operand, source)

      _ ->
        nil
    end
  end

  defp call_target_name(call, source) do
    with target when not is_nil(target) <- TS.node_child_by_field_name(call, "target"),
         "identifier" <- TS.node_kind(target) do
      slice(source, target)
    else
      _ -> nil
    end
  end

  defp field_name(node, field, source) do
    case TS.node_child_by_field_name(node, field) do
      nil -> []
      name -> [named(name, source)]
    end
  end

  defp named(node, source), do: {TS.node_start_byte(node), slice(source, node)}

  defp slice(source, node) do
    s = TS.node_start_byte(node)
    e = TS.node_end_byte(node)
    if e > s, do: binary_part(source, s, e - s), else: ""
  end
end
