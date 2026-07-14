defmodule RetrievalNode.Embedding.LlamaCppSidecarImpl do
  @moduledoc """
  Stub embedding implementation — the documented escape hatch if Bumblebee/EXLA
  proves unworkable on the arm64 target (see `research/exla-aarch64.md`).

  It would speak HTTP (via the shared `RetrievalNode.Finch` pool, added in Phase 8)
  to a `llama.cpp --embedding` server serving the same model, honoring the same
  `RetrievalNode.Embedding` contract so it can be swapped in with zero call-site
  changes:

      config :retrieval_node, :embedding_impl, RetrievalNode.Embedding.LlamaCppSidecarImpl

  Not implemented in v1 — the callbacks raise so a misconfiguration fails loudly
  rather than silently returning bad vectors.
  """

  @behaviour RetrievalNode.Embedding

  # embed/1 and embed_batch/1 are intentional v1 stubs that always raise, so they
  # have no local return — which dialyzer flags against the behaviour's `:: vector`
  # callback. Silence it here; the raising is the desired contract until the real
  # llama.cpp client lands.
  @dialyzer {:nowarn_function, [embed: 1, embed_batch: 1]}

  @dimensions 384

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def embed(_text), do: not_implemented!()

  @impl true
  def embed_batch(_texts), do: not_implemented!()

  defp not_implemented! do
    raise "#{inspect(__MODULE__)} is a v1 stub — see the moduledoc. Use " <>
            "RetrievalNode.Embedding.NxServingImpl, or implement the llama.cpp HTTP client."
  end
end
