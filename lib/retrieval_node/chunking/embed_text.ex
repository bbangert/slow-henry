defmodule RetrievalNode.Chunking.EmbedText do
  @moduledoc """
  The string a chunk is embedded as. Stored `content`, `context_breadcrumb`
  and the FTS `tsv` never contain any of this; it exists only as embedding
  input.

  `build/1` returns `{embed_text, embed_format}`:

    * format `0` — `Breadcrumb.prepend/2` of the chunk text (bare text when
      there is no breadcrumb). Every definition chunk, and every chunk written
      before formats existed.
    * format `1` — `kind: "toplevel"` chunks whose rendering differs from format 0: a header line
      `"<breadcrumb> — defines: N1, N2, ..."` (just the breadcrumb when the
      chunk binds no names), a blank line, then the text with its import
      statements removed (`import_ranges`, from the AST). A chunk that is
      nothing but imports keeps its text so it still embeds something.

  The format records which transformation ACTUALLY applied, not which kind
  the chunk is: a toplevel chunk that binds no names and has no imports to
  strip renders to exactly the format 0 text, so `build/1` returns
  `{legacy_text, 0}` for it. Identical input means an identical vector, so
  reusing the vector written under format 0 is correct and the chunk is not
  re-embedded when format 1 rolls out. The comparison lives here, in `build/1`,
  and nowhere else.

  `embed_format` is part of FileIngest's embedding-reuse key and is persisted
  in `chunks.metadata["embed_format"]`. Changing what a format produces, or
  moving chunks to a new number, forces exactly those chunks to re-embed on
  their next ingest (a forced re-ingest included); bump a number whenever the
  produced text changes for a chunk whose `{breadcrumb, content_hash}` does not.
  """

  alias RetrievalNode.Chunking.Breadcrumb

  @embed_format_plain 0
  @embed_format_toplevel 1

  @type input :: %{
          required(:kind) => String.t() | nil,
          required(:breadcrumb) => String.t() | nil,
          required(:text) => String.t(),
          optional(:names) => [String.t()],
          optional(:import_ranges) => [{non_neg_integer(), non_neg_integer()}]
        }

  @doc "The format number written for chunks that have no format recorded."
  @spec legacy_format() :: non_neg_integer()
  def legacy_format, do: @embed_format_plain

  @spec build(input()) :: {String.t(), non_neg_integer()}
  def build(%{kind: "toplevel", text: text} = chunk) do
    legacy = legacy_text(chunk)
    body = chunk |> Map.get(:import_ranges, []) |> strip_ranges(text) |> body_or(text)
    candidate = join(header(chunk[:breadcrumb], Map.get(chunk, :names, [])), body)

    if candidate == legacy,
      do: {legacy, @embed_format_plain},
      else: {candidate, @embed_format_toplevel}
  end

  def build(chunk), do: {legacy_text(chunk), @embed_format_plain}

  # Exactly what every chunk was embedded as before formats existed.
  defp legacy_text(%{breadcrumb: crumb, text: text}) when crumb in [nil, ""], do: text
  defp legacy_text(%{breadcrumb: crumb, text: text}), do: Breadcrumb.prepend(crumb, text)

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
