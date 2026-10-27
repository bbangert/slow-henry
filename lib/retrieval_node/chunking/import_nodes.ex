defmodule RetrievalNode.Chunking.ImportNodes do
  @moduledoc """
  What counts as an import statement, per language, in one place for the graph
  extractor (which turns imports into `:import` references) and the chunker
  (which records their byte ranges on top-level chunks). Both must classify
  the same nodes, or an import the graph knows about would still be embedded
  as chunk text.

    * most languages: a node whose kind is in `kinds/1`
    * elixir: a `call` whose target identifier is one of `elixir_forms/0`
    * ruby: no import kind; a `require` / `require_relative` call with no or a
      `self` / `Kernel` receiver and a non-interpolated string first argument
      (see `ruby_import/3`)
  """

  alias RetrievalNode.Chunking.BindingNames
  alias TreeSitterLanguagePack, as: TS

  @kinds %{
    "python" => ~w(import_statement import_from_statement),
    "javascript" => ~w(import_statement),
    "typescript" => ~w(import_statement),
    "go" => ~w(import_declaration),
    "rust" => ~w(use_declaration),
    "ruby" => [],
    "java" => ~w(import_declaration)
  }

  @elixir_forms ~w(alias import use require)

  @doc "Import node kinds for `language` (empty for elixir and ruby, which use calls)."
  @spec kinds(String.t()) :: [String.t()]
  def kinds(language), do: Map.get(@kinds, language, [])

  @doc "The Elixir call targets that are import forms."
  @spec elixir_forms() :: [String.t()]
  def elixir_forms, do: @elixir_forms

  @doc "Whether `node` (of `kind`) is an import statement in `language`."
  @spec import?(term(), String.t(), String.t(), binary()) :: boolean()
  def import?(node, "call", "elixir", source),
    do: elixir_identifier(node, source) in @elixir_forms

  def import?(node, "call", "ruby", source) do
    with m when not is_nil(m) <- TS.node_child_by_field_name(node, "method"),
         {:import, _} <- ruby_import(node, source, slice(source, m)) do
      true
    else
      _ -> false
    end
  end

  def import?(_node, kind, language, _source), do: kind in kinds(language)

  # The identifier a call node invokes, or nil (qualified `Mod.fun` targets and
  # `@attr` operands are not import forms).
  defp elixir_identifier(call, source) do
    with target when not is_nil(target) <- TS.node_child_by_field_name(call, "target"),
         "identifier" <- TS.node_kind(target) do
      slice(source, target)
    else
      _ -> nil
    end
  end

  @doc """
  Classifies a Ruby call whose method is `name` as `{:import, path}` (a
  `require`/`require_relative` of a literal string) or `:not_import`.
  """
  @spec ruby_import(term(), binary(), String.t()) :: {:import, String.t()} | :not_import
  def ruby_import(call_node, source, name) when name in ["require", "require_relative"] do
    with true <- ruby_kernel_receiver?(call_node, source),
         str when not is_nil(str) <- first_string_arg(call_node, source) do
      {:import, str}
    else
      _ -> :not_import
    end
  end

  def ruby_import(_call_node, _source, _name), do: :not_import

  defp ruby_kernel_receiver?(call_node, source) do
    case TS.node_child_by_field_name(call_node, "receiver") do
      nil -> true
      recv -> TS.node_kind(recv) == "self" or slice(source, recv) in ["Kernel", "::Kernel"]
    end
  end

  defp first_string_arg(call_node, source) do
    with args_node when not is_nil(args_node) <-
           TS.node_child_by_field_name(call_node, "arguments"),
         [str_node | _] <-
           Enum.filter(BindingNames.named_children(args_node), &(TS.node_kind(&1) == "string")),
         false <-
           Enum.any?(
             BindingNames.named_children(str_node),
             &(TS.node_kind(&1) == "interpolation")
           ) do
      string_content(str_node, source)
    else
      _ -> nil
    end
  end

  defp string_content(str_node, source) do
    case Enum.find(
           BindingNames.named_children(str_node),
           &(TS.node_kind(&1) == "string_content")
         ) do
      nil -> strip_quotes(slice(source, str_node))
      content_node -> slice(source, content_node)
    end
  end

  @doc "Trims whitespace and one layer of `\"`, `'` or backtick quoting."
  @spec strip_quotes(String.t()) :: String.t()
  def strip_quotes(text),
    do: text |> String.trim() |> String.trim("\"") |> String.trim("'") |> String.trim("`")

  defp slice(source, node) do
    s = TS.node_start_byte(node)
    e = TS.node_end_byte(node)
    if e > s, do: binary_part(source, s, e - s), else: ""
  end
end
