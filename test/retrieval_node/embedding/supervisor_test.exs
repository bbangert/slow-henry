defmodule RetrievalNode.Embedding.SupervisorTest do
  # Mutates the process-global `:persistent_term` readiness key that
  # RetrievalNodeWeb.HealthControllerTest and RetrievalNode.Embedding.ServingTest
  # (both async: false) also touch — async: true here would race those files
  # for the same key.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RetrievalNode.Embedding.{Serving, Supervisor, Warmer}

  # Stands in for the real Serving child, which loads a ~1.2 GB Bumblebee model
  # and can't be started in test. Only needs to occupy child position 1 of the
  # rest_for_one pair and be killable — it doesn't need to be a real Nx.Serving.
  defmodule FakeServing do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  setup do
    on_exit(fn -> Serving.reset_ready() end)
  end

  test "init/1 defaults to the production [Serving, Warmer] pair under rest_for_one" do
    # Calling init/1 directly builds child specs without starting anything, so
    # this is safe to run without a model — it just proves the opts seam added
    # for this test suite left the production default (and child_spec) intact.
    # Serving.child_spec/1 overrides :id to Serving.name() (the registered Nx.Serving
    # process name), not the module — Warmer uses the default (its own module name).
    assert {:ok, {%{strategy: :rest_for_one}, child_specs}} = Supervisor.init([])
    assert Enum.map(child_specs, & &1.id) == [Serving.name(), Warmer]
  end

  test "a Serving crash restarts Warmer too, which resets ready? (rest_for_one)" do
    capture_log(fn ->
      start_supervised!({Supervisor, children: [FakeServing, Warmer]})

      original_serving_pid = Process.whereis(FakeServing)
      original_warmer_pid = Process.whereis(Warmer)
      assert is_pid(original_serving_pid)
      assert is_pid(original_warmer_pid)

      # Simulate a completed warmup from before the crash, so the reset below
      # is observable rather than coincidentally already false.
      :persistent_term.put({Serving, :ready?}, true)
      assert Serving.ready?()

      serving_ref = Process.monitor(original_serving_pid)
      warmer_ref = Process.monitor(original_warmer_pid)

      Process.exit(original_serving_pid, :kill)

      assert_receive {:DOWN, ^serving_ref, :process, ^original_serving_pid, :killed}, 1000

      # rest_for_one terminates every child after the crashed one too, so
      # Warmer goes down (and restarts) even though it wasn't killed directly.
      assert_receive {:DOWN, ^warmer_ref, :process, ^original_warmer_pid, _reason}, 1000

      new_serving_pid = wait_for_new_pid(FakeServing, original_serving_pid)
      new_warmer_pid = wait_for_new_pid(Warmer, original_warmer_pid)

      assert new_serving_pid != original_serving_pid
      assert new_warmer_pid != original_warmer_pid

      # `Process.whereis/1` can observe the new Warmer's name registered before
      # its init/1 (and handle_continue's warmup) actually run — gen_server
      # registers the name, then calls init, and the scheduler can preempt in
      # between. `:sys.get_state/1` only replies once the process has finished
      # init + handle_continue and reached its receive loop, so it's a safe
      # synchronization point before asserting on ready?.
      :sys.get_state(new_warmer_pid)

      # This is the load-bearing claim in Embedding.Supervisor's moduledoc: the
      # restarted Warmer's init/1 resets ready? synchronously, and its re-warmup
      # attempt exits harmlessly against the still-unregistered Serving.name()
      # (there's no real Nx.Serving in this test), so ready? stays false instead
      # of staying stuck at the pre-crash `true`.
      refute Serving.ready?()
    end)
  end

  # rest_for_one restarts asynchronously relative to this test process, so poll
  # briefly for the new pid instead of asserting immediately after the :DOWN.
  defp wait_for_new_pid(name, old_pid, deadline \\ System.monotonic_time(:millisecond) + 2000)

  defp wait_for_new_pid(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("timed out waiting for #{inspect(name)} to restart")
        else
          Process.sleep(10)
          wait_for_new_pid(name, old_pid, deadline)
        end
    end
  end
end
