defmodule RetrievalNode.Chunking.Attachments do
  @moduledoc """
  Leading attachments of a definition chunk: the nodes that belong to a
  definition but sit outside its own AST node.

  A definition's chunk starts at the start of its attachment run — the
  contiguous run of preceding siblings (same scope, nothing but whitespace
  between them) that are one of:

    * the definition's syntactic wrapper (`wrapper?/2`: Python
      `decorated_definition`, JS/TS `export_statement`, TS `ambient_declaration`),
      whose start already includes decorators and `export`;
    * a sibling attribute/decorator node (TS method `decorator`, Rust
      `attribute_item`, Elixir `@doc`/`@spec`/`@impl`/`@deprecated`/`@typedoc`);
    * a doc comment: a comment that ends on the line above the run (or the
      line of its first node) and starts its own line. Rust only counts
      outer doc comments (`///`, `/** */`).

  Data attributes such as Elixir `@limit 3` are not attachments: they are bound
  names and stay in the gap. Java modifiers/annotations and Python/TS class
  decorators already live inside the declaration node.

  Python quirk: a comment between a `class X:` line and its first member is
  parsed outside the class body, so it is not a sibling of that member.
  """

  alias RetrievalNode.Chunking.BindingNames
  alias TreeSitterLanguagePack, as: TS

  @wrappers %{
    "python" => ~w(decorated_definition),
    "javascript" => ~w(export_statement),
    "typescript" => ~w(export_statement ambient_declaration)
  }

  # Sibling kinds that always attach to the run that follows them.
  @attachment_kinds %{
    "python" => ~w(decorator),
    "javascript" => ~w(decorator),
    "typescript" => ~w(decorator),
    "rust" => ~w(attribute_item)
  }

  @comment_kinds %{
    "python" => ~w(comment),
    "javascript" => ~w(comment),
    "typescript" => ~w(comment),
    "go" => ~w(comment),
    "ruby" => ~w(comment),
    "elixir" => ~w(comment),
    "java" => ~w(line_comment block_comment),
    "rust" => ~w(line_comment block_comment)
  }

  @elixir_doc_attrs ~w(doc spec impl deprecated typedoc)

  @typedoc "`{byte, zero-based row}` of the first byte of a chunk."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @doc "True when nodes of `kind` wrap a definition and may carry a lead down to it."
  @spec wrapper?(String.t(), String.t()) :: boolean()
  def wrapper?(kind, language), do: kind in Map.get(@wrappers, language, [])

  @doc """
  Where the chunk for `node` starts, and how many of the nearest `preceding`
  siblings (nearest first) its attachment run absorbs. `inherited` is the lead
  of an enclosing wrapper (or `nil`). Absorbed siblings belong to the chunk:
  the caller must not look for boundaries inside them.
  """
  @spec lead(term(), [term()], position() | nil, binary(), String.t()) ::
          {position(), non_neg_integer()}
  def lead(node, preceding, inherited, source, language) do
    {own, absorbed} = run_start(preceding, position(node), 0, source, language)

    case inherited do
      {byte, _row} = outer when byte < elem(own, 0) -> {outer, absorbed}
      _ -> {own, absorbed}
    end
  end

  defp run_start([], current, count, _source, _language), do: {current, count}

  defp run_start([sibling | rest], {_byte, row} = current, count, source, language) do
    if attachment?(sibling, row, source, language) do
      run_start(rest, position(sibling), count + 1, source, language)
    else
      {current, count}
    end
  end

  defp attachment?(sibling, next_row, source, language) do
    kind = TS.node_kind(sibling)

    cond do
      kind in Map.get(@attachment_kinds, language, []) ->
        true

      kind in Map.get(@comment_kinds, language, []) ->
        doc_comment?(sibling, next_row, source, language)

      language == "elixir" ->
        elixir_doc_attribute?(sibling, source)

      true ->
        false
    end
  end

  defp doc_comment?(comment, next_row, source, language) do
    ends_above?(comment, next_row) and standalone?(comment, source) and
      (language != "rust" or rust_outer_doc?(comment))
  end

  defp ends_above?(comment, next_row), do: last_row(comment) >= next_row - 1

  # Nothing but whitespace precedes the comment on its start line (a comment
  # after code, even `{ // note`, belongs to that code).
  defp standalone?(comment, source), do: blank_before?(source, TS.node_start_byte(comment))

  defp blank_before?(_source, 0), do: true

  defp blank_before?(source, byte) do
    case :binary.at(source, byte - 1) do
      c when c in [?\s, ?\t] -> blank_before?(source, byte - 1)
      c when c in [?\n, ?\r] -> true
      _ -> false
    end
  end

  # A line comment's node includes its newline, ending at column 0 of the next
  # row; that row is not one the comment occupies.
  defp last_row(node) do
    start_row = TS.node_start_position(node).row
    %{row: row, column: column} = TS.node_end_position(node)
    if column == 0 and row > start_row, do: row - 1, else: row
  end

  defp rust_outer_doc?(comment),
    do:
      Enum.any?(
        BindingNames.named_children(comment),
        &(TS.node_kind(&1) == "outer_doc_comment_marker")
      )

  # `@doc ...` is a `unary_operator` whose operand is a call to `doc`; a data
  # attribute (`@limit 3`) has the same shape with another target.
  defp elixir_doc_attribute?(node, source) do
    with "unary_operator" <- TS.node_kind(node),
         operator when not is_nil(operator) <- TS.node_child_by_field_name(node, "operator"),
         "@" <- text(operator, source),
         [operand | _] <- BindingNames.named_children(node),
         "call" <- TS.node_kind(operand),
         target when not is_nil(target) <- TS.node_child_by_field_name(operand, "target") do
      text(target, source) in @elixir_doc_attrs
    else
      _ -> false
    end
  end

  defp text(node, source) do
    start_byte = TS.node_start_byte(node)
    binary_part(source, start_byte, TS.node_end_byte(node) - start_byte)
  end

  defp position(node), do: {TS.node_start_byte(node), TS.node_start_position(node).row}
end
