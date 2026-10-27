defmodule RetrievalNode.Chunking.EmbedText do
  @moduledoc """
  The string a chunk is embedded as. Stored `content`, `context_breadcrumb`
  and the FTS `tsv` never contain any of this; it exists only as embedding
  input.

  `build/1` returns the string:

    * everything but `kind: "toplevel"` — `legacy_text/2`: `Breadcrumb.prepend/2`
      of the chunk text (bare text when there is no breadcrumb). This is also
      what every chunk was embedded as before this module existed.
    * `kind: "toplevel"` — a header line `"<breadcrumb> — defines: N1, N2, ..."`
      (just the breadcrumb when the chunk binds no names), a blank line, then
      the text with its import statements removed (`import_ranges`, from the
      AST). A chunk that is nothing but imports keeps its text so it still
      embeds something. A chunk with no names and no imports renders to exactly
      `legacy_text/2`.

  Names and import ranges depend on the enclosing AST, not only on the chunk's
  own text, so identical `{breadcrumb, content}` can render differently.
  Embedding reuse (FileIngest) therefore keys on the sha256 of this string, the
  actual embedder input: an identical input is an identical vector, and nothing
  else is assumed to be. Rows written before the hash was stored are keyed by
  `legacy_text/2` of their stored breadcrumb and content.
  """

  alias RetrievalNode.Chunking.Breadcrumb

  @type input :: %{
          required(:kind) => String.t() | nil,
          required(:breadcrumb) => String.t() | nil,
          required(:text) => String.t(),
          optional(:names) => [String.t()],
          optional(:import_ranges) => [{non_neg_integer(), non_neg_integer()}]
        }

  @spec build(input()) :: String.t()
  def build(%{kind: "toplevel", text: text} = chunk) do
    body = chunk |> Map.get(:import_ranges, []) |> strip_ranges(text) |> body_or(text)
    join(header(chunk[:breadcrumb], Map.get(chunk, :names, [])), body)
  end

  def build(%{breadcrumb: crumb, text: text}), do: legacy_text(crumb, text)

  @doc "The embedder input as it was before `build/1` existed."
  @spec legacy_text(String.t() | nil, String.t()) :: String.t()
  def legacy_text(crumb, text) when crumb in [nil, ""], do: text
  def legacy_text(crumb, text), do: Breadcrumb.prepend(crumb, text)

  defp header(crumb, _names) when crumb in [nil, ""], do: nil
  defp header(crumb, []), do: crumb
  defp header(crumb, names), do: crumb <> " — defines: " <> Enum.join(names, ", ")

  defp join(nil, body), do: body
  defp join(header, body), do: header <> "\n\n" <> body

  defp body_or("", text), do: text
  defp body_or(body, _text), do: body

  # Removes the ranges (sorted, non-overlapping, byte offsets into `text`),
  # then collapses the runs of blank (or indentation-only)
  # lines they leave behind. Text with no imports
  # is embedded as written.
  defp strip_ranges([], text), do: text

  defp strip_ranges(ranges, text) do
    {kept, pos} =
      Enum.reduce(ranges, {[], 0}, fn {s, e}, {acc, pos} ->
        {[binary_part(text, pos, s - pos) | acc], e}
      end)

    [binary_part(text, pos, byte_size(text) - pos) | kept]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.replace(~r/\n(?:[ \t]*\n){2,}/, "\n\n")
    |> String.trim()
  end
end
