defmodule RetrievalNode.Chunking.HeuristicImpl do
  @moduledoc """
  Pure-Elixir fallback chunker — no NIF, no tree-sitter. Splits source at
  blank-line boundaries while respecting brace balance (never ends a chunk in the
  middle of a `{...}` block) and a soft byte cap, so a chunk stays a
  syntactically-plausible span even without a parse. Language-agnostic.

  It is both the automatic fallback (size cap, binary content, unsupported
  language, or a tree-sitter timeout/crash) and the `:test`-env default. Chunks
  carry `parse_status: :heuristic_fallback`; a caller falling back after a
  tree-sitter *crash* may relabel them `:crashed_fallback`.
  """

  @behaviour RetrievalNode.Chunking

  alias RetrievalNode.Chunking.TreeSitterImpl

  # Soft target chunk size; a chunk may exceed it only to reach a brace-balanced
  # boundary rather than split mid-block.
  @max_chunk_bytes 1_500

  # Hard ceiling: force a boundary regardless of brace balance. Without it, an
  # unmatched brace inside a string/comment literal keeps `balance` positive
  # forever so the soft cap never fires, and the rest of the file accumulates
  # into one unbounded chunk. (A single physical line longer than this still
  # yields one chunk — bounded by the upstream 2MB file cap in TreeSitterImpl.)
  @hard_max_bytes 6_000

  @impl true
  def allowed_languages, do: TreeSitterImpl.allowed_languages()

  @impl true
  def chunk(source, _language) when is_binary(source) do
    chunks =
      source
      |> normalize_newlines()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(new_acc(), &step/2)
      |> flush()
      |> Enum.reverse()

    {:ok, chunks}
  end

  # Normalize CRLF/CR to LF so `\r` doesn't leak into chunk text (or the embedded
  # vector) on Windows-authored files.
  defp normalize_newlines(source), do: String.replace(source, ~r/\r\n?/, "\n")

  defp new_acc, do: %{chunks: [], lines: [], start: nil, balance: 0, bytes: 0}

  # `lines` accumulates {line, line_number} in reverse for the in-progress chunk.
  # Skip leading blank lines between chunks — don't start a chunk on whitespace.
  defp step({line, _idx} = entry, %{lines: []} = acc) do
    if blank?(line), do: acc, else: accumulate(entry, acc)
  end

  defp step(entry, acc), do: accumulate(entry, acc)

  defp accumulate({line, idx}, acc) do
    balance = acc.balance + brace_delta(line)
    lines = [{line, idx} | acc.lines]
    bytes = acc.bytes + byte_size(line) + 1
    start = acc.start || idx

    soft_boundary? =
      balance <= 0 and (blank?(line) or bytes >= @max_chunk_bytes) and acc.lines != []

    # Hard cap fires regardless of brace balance — the safety valve.
    hard_boundary? = bytes >= @hard_max_bytes

    if soft_boundary? or hard_boundary? do
      reset(%{acc | chunks: [build(lines, start) | acc.chunks]})
    else
      %{acc | lines: lines, start: start, balance: max(balance, 0), bytes: bytes}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp reset(acc), do: %{acc | lines: [], start: nil, balance: 0, bytes: 0}

  defp flush(%{lines: []} = acc), do: acc.chunks
  defp flush(%{lines: lines, start: start} = acc), do: [build(lines, start) | acc.chunks]

  defp build(rev_lines, start_line) do
    # Drop trailing blank lines so the chunk ends on real content.
    lines =
      rev_lines
      |> Enum.drop_while(fn {line, _} -> String.trim(line) == "" end)
      |> Enum.reverse()

    {_, end_line} = List.last(lines)
    text = Enum.map_join(lines, "\n", &elem(&1, 0))

    %{
      text: text,
      breadcrumb: "",
      start_line: start_line,
      end_line: end_line,
      kind: "heuristic_block",
      parse_status: :heuristic_fallback
    }
  end

  defp brace_delta(line) do
    graphemes = String.graphemes(line)
    Enum.count(graphemes, &(&1 == "{")) - Enum.count(graphemes, &(&1 == "}"))
  end
end
