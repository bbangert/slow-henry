defmodule RetrievalNodeWeb.HealthControllerTest do
  # Mutates global Application env (:embedding_serving_start) in the 503 test,
  # so this file must run async: false to avoid racing other test processes
  # that read the same key.
  use RetrievalNodeWeb.ConnCase, async: false

  alias RetrievalNode.Embedding.Serving

  describe "GET /healthz — all config-disabled subsystems skipped, DB real" do
    test "200 with every gate ok or skipped", %{conn: conn} do
      conn = get(conn, ~p"/healthz")

      assert %{
               "status" => "ok",
               "checks" => %{
                 "grammar_cache" => %{"status" => "skipped"},
                 "nx_backend" => %{"status" => "skipped"},
                 "embedding_warm" => %{"status" => "skipped"},
                 "db" => %{"status" => "ok"}
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /healthz — a real failing gate" do
    setup do
      original = Application.get_env(:retrieval_node, :embedding_serving_start, false)
      Application.put_env(:retrieval_node, :embedding_serving_start, true)
      Serving.reset_ready()

      on_exit(fn ->
        Application.put_env(:retrieval_node, :embedding_serving_start, original)
        Serving.reset_ready()
      end)

      :ok
    end

    test "503 with embedding_warm failed (serving never started in test)", %{conn: conn} do
      conn = get(conn, ~p"/healthz")

      assert %{
               "status" => "error",
               "checks" => %{
                 "embedding_warm" => %{"status" => "error", "detail" => %{"ready" => false}}
               }
             } = json_response(conn, 503)
    end
  end

  describe "GET /healthz — grammar_cache gate mirrors Chunking.impl/0, not a raw config lookup" do
    alias RetrievalNode.Chunking.{FakeGrammarPack, Grammars}

    setup do
      # Simulate a host where :chunking_impl was never set — Chunking.impl/0
      # then falls back to TreeSitterImpl, so grammar_cache must actually run
      # (not report "skipped" the way a bare Application.get_env/2 with no
      # default would).
      original_chunking_impl = Application.get_env(:retrieval_node, :chunking_impl)
      Application.delete_env(:retrieval_node, :chunking_impl)
      Application.put_env(:retrieval_node, :grammar_pack_mod, FakeGrammarPack)
      Application.put_env(:retrieval_node, :fake_downloaded_languages, Grammars.required())

      on_exit(fn ->
        Application.put_env(:retrieval_node, :chunking_impl, original_chunking_impl)
        Application.delete_env(:retrieval_node, :grammar_pack_mod)
        Application.delete_env(:retrieval_node, :fake_downloaded_languages)
      end)

      :ok
    end

    test "grammar_cache runs (not skipped) when :chunking_impl is unset", %{conn: conn} do
      conn = get(conn, ~p"/healthz")

      assert %{"checks" => %{"grammar_cache" => %{"status" => "ok"}}} =
               json_response(conn, 200)
    end
  end
end
