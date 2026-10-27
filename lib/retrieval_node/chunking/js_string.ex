defmodule RetrievalNode.Chunking.JsString do
  @moduledoc """
  The single decoder for JavaScript/TypeScript string-literal values, shared by
  the graph extractor and the chunker's binding names so a literal means the
  same thing in both. Reads a literal's `string_fragment` and `escape_sequence`
  children (never trimming quotes off the source text); a template literal
  without substitutions decodes the same way, one with substitutions is `nil`.
  """

  alias RetrievalNode.Chunking.BindingNames
  alias TreeSitterLanguagePack, as: TS

  # The decoded value of a js/ts string literal, from its `string_fragment` and
  # `escape_sequence` children (never by trimming quotes off the source text,
  # which would also strip quotes that are part of the value). nil when the
  # literal can't be decoded to valid UTF-8 (e.g. a lone surrogate escape).
  def value(str_node, source) do
    str_node
    |> BindingNames.named_children()
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
  def decode_identifier(name) when is_binary(name) do
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

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    end_byte = TS.node_end_byte(node)
    if end_byte > start_byte, do: binary_part(source, start_byte, end_byte - start_byte), else: ""
  end
end
