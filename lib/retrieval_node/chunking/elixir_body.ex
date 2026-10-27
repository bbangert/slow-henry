defmodule RetrievalNode.Chunking.ElixirBody do
  @moduledoc """
  How an Elixir definition call (`defmodule`, `def`, ...) carries its body, in
  one place for the graph extractor and the chunker's binding names: a
  `do_block` child, and/or the values of keyword-form pairs (`do: expr`, also
  `rescue:` ... for functions). Both shapes must be traversed alike, or a
  `defmodule M, do: @foo 1` body is seen by one consumer and missed by the
  other.
  """

  alias RetrievalNode.Chunking.BindingNames
  alias TreeSitterLanguagePack, as: TS

  @doc """
  A definition's body nodes: its `do_block`s plus the values of its keyword-form
  body pairs — all of them for `:all`, else only the pairs whose key is in
  `keys`.
  """
  @spec body_nodes(term(), :all | [String.t()], binary()) :: [term()]
  def body_nodes(call_node, keys, source) do
    blocks =
      call_node |> BindingNames.named_children() |> Enum.filter(&(TS.node_kind(&1) == "do_block"))

    values =
      for pair <- keyword_pairs(call_node),
          keys == :all or pair_key(pair, source) in keys,
          value = TS.node_child_by_field_name(pair, "value"),
          not is_nil(value),
          do: value

    blocks ++ values
  end

  @doc """
  Keyword options of a call: bare (`f x, k: v`) or a literal list
  (`f x, [k: v]`), which Elixir treats identically.
  """
  @spec keyword_pairs(term()) :: [term()]
  def keyword_pairs(call_node) do
    call_node
    |> arguments()
    |> Enum.flat_map(fn arg ->
      case TS.node_kind(arg) do
        "keywords" ->
          [arg]

        "list" ->
          arg |> BindingNames.named_children() |> Enum.filter(&(TS.node_kind(&1) == "keywords"))

        _ ->
          []
      end
    end)
    |> Enum.flat_map(&BindingNames.named_children/1)
    |> Enum.filter(&(TS.node_kind(&1) == "pair"))
  end

  @spec pair_key(term(), binary()) :: String.t() | nil
  def pair_key(pair, source) do
    case TS.node_child_by_field_name(pair, "key") do
      nil -> nil
      key -> key |> then(&slice(source, &1)) |> String.trim() |> String.trim_trailing(":")
    end
  end

  @doc "The named children of a call's `arguments` node, comments excluded."
  @spec arguments(term()) :: [term()]
  def arguments(call_node) do
    case call_node
         |> BindingNames.named_children()
         |> Enum.find(&(TS.node_kind(&1) == "arguments")) do
      nil ->
        []

      args ->
        args |> BindingNames.named_children() |> Enum.reject(&(TS.node_kind(&1) == "comment"))
    end
  end

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    end_byte = TS.node_end_byte(node)
    if end_byte > start_byte, do: binary_part(source, start_byte, end_byte - start_byte), else: ""
  end
end
