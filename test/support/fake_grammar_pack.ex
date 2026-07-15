defmodule RetrievalNode.Chunking.FakeGrammarPack do
  @moduledoc """
  Test-only stand-in for `TreeSitterLanguagePack` behind `:grammar_pack_mod`
  (see `RetrievalNode.Chunking.Grammars`), so `missing/0`, `all_cached?/0` and
  `prefetch/1` are testable without ever calling the NIF. Driven by
  `:fake_downloaded_languages` and `:fake_download_result` application env,
  same pattern as `Chunking.FakeImpl`.
  """

  @spec downloaded_languages() :: [String.t()]
  def downloaded_languages,
    do: Application.get_env(:retrieval_node, :fake_downloaded_languages, [])

  @spec download([String.t()]) :: {:ok, non_neg_integer()} | {:error, atom(), String.t()}
  def download(_languages) do
    Application.get_env(:retrieval_node, :fake_download_result, {:ok, 0})
  end
end
