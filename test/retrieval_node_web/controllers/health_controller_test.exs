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
end
