defmodule RetrievalNode.Chunking.FakeImpl do
  @moduledoc """
  Test-only `Chunking` implementation whose `chunk/2` return is dictated by the
  `:fake_chunk_result` application env. Lets `ChunkFiles`-scoped tests force the
  fallback/skip branches (`:unsupported_language`, `:too_large`, `:binary_content`,
  a crash reason) that the real `HeuristicImpl` can never produce.
  """
  @behaviour RetrievalNode.Chunking

  @impl true
  def chunk(_source, _language) do
    Application.get_env(:retrieval_node, :fake_chunk_result, {:ok, []})
  end

  @impl true
  def allowed_languages, do: []
end
