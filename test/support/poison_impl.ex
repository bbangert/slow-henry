defmodule RetrievalNode.Chunking.PoisonImpl do
  @moduledoc """
  Test-only `Chunking` impl whose `chunk/2` fails deterministically for
  content starting with "POISON" (and throws for "THROW") and otherwise delegates to the real
  `HeuristicImpl` — lets a test seed both a poison row and healthy rows in the
  same pass without disturbing the rest of the suite's `:fake_chunk_result`-
  driven `FakeImpl`.
  """
  @behaviour RetrievalNode.Chunking

  alias RetrievalNode.Chunking.HeuristicImpl

  @impl true
  def chunk("POISON" <> _, _lang), do: {:error, :boom}
  def chunk("THROW" <> _, _lang), do: throw(:boom_throw)
  def chunk(source, lang), do: HeuristicImpl.chunk(source, lang)

  @impl true
  def allowed_languages, do: []
end
