defmodule RetrievalNode.Chunking.FakeImpl do
  @moduledoc """
  Test-only `Chunking` implementation whose `chunk/2` return is dictated by the
  `:fake_chunk_result` application env. Lets `Ingest.FileIngest`-scoped tests
  force the fallback/skip branches (`:unsupported_language`, `:too_large`,
  `:binary_content`, a crash reason) that the real `HeuristicImpl` can never
  produce.

  `chunk_with_graph/2` is dictated separately by `:fake_chunk_with_graph_result`
  so graph-focused tests can hand back controlled entities/references without
  disturbing the plain-`chunk/2` error-branch tests above. When unset, it falls
  back to wrapping `chunk/2`'s result with empty graph lists — the same
  wrapping `RetrievalNode.Chunking.chunk_with_graph/2` does for any impl that
  doesn't define this callback — so existing `fake_chunk_result`-only tests
  keep working unchanged now that `Ingest.FileIngest` calls `chunk_with_graph/2`.
  """
  @behaviour RetrievalNode.Chunking

  @impl true
  def chunk(_source, _language) do
    Application.get_env(:retrieval_node, :fake_chunk_result, {:ok, []})
  end

  @impl true
  def allowed_languages, do: []

  @impl true
  def chunk_with_graph(source, language) do
    case Application.get_env(:retrieval_node, :fake_chunk_with_graph_result) do
      nil ->
        case chunk(source, language) do
          {:ok, chunks} -> {:ok, %{chunks: chunks, entities: [], references: []}}
          {:error, reason} -> {:error, reason}
        end

      result ->
        result
    end
  end
end
