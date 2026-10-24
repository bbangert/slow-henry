defmodule RetrievalNode.Embedding.ServingTest do
  # Mutates the process-global `:persistent_term` readiness key that
  # RetrievalNodeWeb.HealthControllerTest (also async: false) reads/writes —
  # async: true here would race that file for the same key.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RetrievalNode.Embedding.{Serving, Warmer}

  # embedding_serving_start is false in :test (config/test.exs), so neither
  # Serving nor Warmer run under the application tree here — these tests own
  # the persistent_term flag and any Warmer process they start directly.

  describe "ready?/0 and reset_ready/0" do
    test "reset_ready/0 flips ready?/0 back to false" do
      :persistent_term.put({Serving, :ready?}, true)
      assert Serving.ready?()

      Serving.reset_ready()

      refute Serving.ready?()
    end
  end

  describe "start_link/1" do
    test "clears readiness before the replacement serving initializes" do
      :persistent_term.put({Serving, :ready?}, true)
      parent = self()

      # The serving's init callback runs inside Nx.Serving.start_link; it reports
      # the readiness it observes there, i.e. while the replacement is starting.
      serving =
        Nx.Serving.new(fn _opts ->
          send(parent, {:ready_during_init, Serving.ready?()})
          fn batch -> batch end
        end)

      {:ok, pid} = Serving.start_link(serving: serving, name: __MODULE__.TestServing)
      on_exit(fn -> Process.alive?(pid) && Process.exit(pid, :kill) end)

      assert_receive {:ready_during_init, false}
      refute Serving.ready?()
    end
  end

  describe "Warmer" do
    test "init/1 resets the readiness flag before warmup runs" do
      :persistent_term.put({Serving, :ready?}, true)
      assert Serving.ready?()

      # warmup/0 has no serving process to call in this test (Serving isn't
      # started) — it exits :noproc, which Serving.warmup/0 catches and logs.
      # The reset in Warmer's init/1 is synchronous (completes before
      # start_supervised!/1 returns), independent of that async warmup outcome.
      capture_log(fn ->
        pid = start_supervised!(Warmer)
        assert Process.alive?(pid)
      end)

      refute Serving.ready?()
    end
  end
end
