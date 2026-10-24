defmodule RetrievalNode.Graph.Extractor.LLMTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Graph.Extractor.LLM

  test "implements the RetrievalNode.Graph.Extractor behaviour" do
    assert RetrievalNode.Graph.Extractor in (LLM.module_info(:attributes)
                                             |> Keyword.get_values(:behaviour)
                                             |> List.flatten())
  end

  test "extract/3 returns {:error, :not_configured} — the deliberate unimplemented seam" do
    assert LLM.extract("def foo(): pass", "python", []) == {:error, :not_configured}
  end
end
