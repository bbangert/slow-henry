defmodule RetrievalNode.Chunking.GrammarsTest do
  # Mutates :grammar_pack_mod / fake_* application env, so keep this file async: false.
  use ExUnit.Case, async: false

  alias RetrievalNode.Chunking.{FakeGrammarPack, Grammars, TreeSitterImpl}

  setup do
    Application.put_env(:retrieval_node, :grammar_pack_mod, FakeGrammarPack)

    on_exit(fn ->
      Application.delete_env(:retrieval_node, :grammar_pack_mod)
      Application.delete_env(:retrieval_node, :fake_downloaded_languages)
      Application.delete_env(:retrieval_node, :fake_download_result)
    end)

    :ok
  end

  describe "required/0" do
    test "is TreeSitterImpl.allowed_languages/0 plus elixir/heex/eex" do
      required = Grammars.required()

      for lang <- TreeSitterImpl.allowed_languages() do
        assert lang in required
      end

      assert "elixir" in required
      assert "heex" in required
      assert "eex" in required
    end
  end

  describe "missing/0 and all_cached?/0 (NIF-free via :grammar_pack_mod)" do
    test "missing/0 is required/0 minus what's downloaded" do
      Application.put_env(:retrieval_node, :fake_downloaded_languages, Grammars.required())

      assert Grammars.missing() == []
    end

    test "missing/0 reports languages absent from the fake download list" do
      Application.put_env(:retrieval_node, :fake_downloaded_languages, ["python"])

      missing = Grammars.missing()
      assert "elixir" in missing
      refute "python" in missing
    end

    test "all_cached?/0 is true only when nothing is missing" do
      Application.put_env(:retrieval_node, :fake_downloaded_languages, Grammars.required())
      assert Grammars.all_cached?()

      Application.put_env(:retrieval_node, :fake_downloaded_languages, [])
      refute Grammars.all_cached?()
    end
  end

  describe "prefetch/0 and prefetch/1 (NIF-free via :grammar_pack_mod)" do
    test "prefetch/1 passes through a successful download result" do
      Application.put_env(:retrieval_node, :fake_download_result, {:ok, 3})
      assert {:ok, 3} = Grammars.prefetch(["python", "go"])
    end

    test "prefetch/0 uses required/0 and passes through an error result" do
      Application.put_env(
        :retrieval_node,
        :fake_download_result,
        {:error, :network, "boom"}
      )

      assert {:error, :network, "boom"} = Grammars.prefetch()
    end
  end
end
