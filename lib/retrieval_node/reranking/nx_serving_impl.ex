defmodule RetrievalNode.Reranking.NxServingImpl do
  @moduledoc """
  Default reranking implementation: in-process Bumblebee/`Nx.Serving`
  cross-encoder over cross-encoder/ms-marco-MiniLM-L-6-v2.

  The serving (`RetrievalNode.Reranking.Serving`) scores `{query, passage}`
  pairs directly (a cross-encoder attends over both texts jointly, unlike the
  bi-encoder in `RetrievalNode.Embedding`), returning one raw logit per pair.
  This module's only job on top of the serving is pairing each passage with
  the query and applying a byte-size guard (`truncate_passage/1`) before the
  pair reaches tokenization.
  """

  @behaviour RetrievalNode.Reranking

  alias RetrievalNode.Reranking.Serving

  # Byte cap applied to each passage before it is paired with the query. This
  # is NOT a correctness requirement: the cross_encoding serving's tokenizer
  # is configured with `length: sequence_length`, so the joint {query,
  # passage} pair is already truncated/padded to the compiled token bucket
  # (see Bumblebee.Text.CrossEncoding) regardless of what we do here. The cap
  # exists for two other reasons: (a) bound tokenization cost on pathological
  # multi-hundred-KB chunks — passages can be up to 2 MB, and running the
  # tokenizer over all of that just to have it discard everything past the
  # token budget is wasted CPU on the query-latency-sensitive search path; and
  # (b) preserve the passage's leading content — a code chunk's signature/
  # opening lines, its highest-signal region — from being competed out by the
  # query text during tokenizer truncation. 2,000 bytes stays comfortably
  # under the 512-token pair budget's passage share for typical code (~4
  # bytes/token), so in practice this cap is rarely the thing doing the
  # truncating; the tokenizer's token-level truncation still is.
  @max_passage_bytes 2_000

  # Byte cap applied to the query text before it's paired with every passage.
  # Unlike the passage cap, this one isn't about a single oversized input —
  # it's about the query being the SAME text repeated across all ~50 pairs in
  # one rerank_scores/2 call. An untruncated multi-KB caller-supplied query
  # (unlike passages, this text is a search question, not a code chunk, so it
  # has no legitimate reason to be large) would have its tokenizer cost paid
  # once per pair instead of once, and could alone consume the entire
  # 512-token pair budget, crowding out the passage half of every pair. 512
  # bytes is generous for a real question while bounding that cost.
  @max_query_bytes 512

  @impl true
  def rerank_scores(query, passages) when is_binary(query) and is_list(passages) do
    truncated_query = truncate_query(query)
    pairs = Enum.map(passages, &{truncated_query, truncate_passage(&1)})

    # The input is always a list, so the serving always returns a list of
    # per-pair %{score: float} results (never a bare single map).
    Serving.name()
    |> Nx.Serving.batched_run(pairs)
    |> Enum.map(& &1.score)
  end

  @doc """
  Truncate `query` to at most #{@max_query_bytes} bytes — same codepoint-safe
  mechanism as `truncate_passage/1`, just with the query's own (smaller)
  budget. Pure (no serving/model), so it is unit-testable in isolation.
  """
  @spec truncate_query(String.t()) :: String.t()
  def truncate_query(query) when is_binary(query), do: truncate(query, @max_query_bytes)

  @doc """
  Truncate `passage` to at most #{@max_passage_bytes} bytes without splitting
  a UTF-8 codepoint. Pure (no serving/model), so it is unit-testable in
  isolation.

  Takes a cheap `binary_part/3` prefix rather than `String.slice/2` (which
  would walk the whole binary counting graphemes) — passages can be up to 2 MB,
  and this only needs to run in time proportional to the cap, not the input
  size. The byte-level cut can land mid-codepoint, so any trailing bytes that
  don't form a complete codepoint are trimmed off afterward (at most 3 bytes,
  since UTF-8 codepoints are at most 4 bytes).
  """
  @spec truncate_passage(String.t()) :: String.t()
  def truncate_passage(passage) when is_binary(passage), do: truncate(passage, @max_passage_bytes)

  # Shared byte-cap mechanism behind truncate_query/1 and truncate_passage/1:
  # a cheap binary_part/3 prefix cut, with any trailing bytes that don't form
  # a complete UTF-8 codepoint trimmed off afterward.
  defp truncate(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      text
      |> binary_part(0, max_bytes)
      |> trim_incomplete_codepoint()
    end
  end

  defp trim_incomplete_codepoint(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_incomplete_codepoint(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
