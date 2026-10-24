defmodule RetrievalNode.Reranking.ServingTest do
  # Mutates the process-global `:persistent_term` readiness key that
  # RetrievalNodeWeb.HealthControllerTest (also async: false) reads/writes.
  use ExUnit.Case, async: false

  alias RetrievalNode.Reranking.Serving

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
end
