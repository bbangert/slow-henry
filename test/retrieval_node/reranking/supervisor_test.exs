defmodule RetrievalNode.Reranking.SupervisorTest do
  # Mutates the process-global `:persistent_term` readiness key that other
  # reranking tests (also async: false) touch — async: true here would race
  # those files for the same key.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RetrievalNode.FakeServing
  alias RetrievalNode.Reranking.{Serving, Supervisor, Warmer}

  setup do
    on_exit(fn -> Serving.reset_ready() end)
  end

  test "the production default is the [Serving, Warmer] pair" do
    # Asserted via default_children/0, NOT by calling init([]) — init/1 with
    # the production default materializes Serving.child_spec/1, which builds
    # the Bumblebee serving and downloads the real model on a cold cache
    # (observed as a surprise model download in CI). The rest_for_one strategy
    # and restart semantics are covered by the fake-children tests below.
    assert Supervisor.default_children() == [Serving, Warmer]
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

      # This is the load-bearing claim in Reranking.Supervisor's moduledoc: the
      # restarted Warmer's init/1 resets ready? synchronously, and its re-warmup
      # attempt exits harmlessly against the still-unregistered Serving.name()
      # (there's no real Nx.Serving in this test), so ready? stays false instead
      # of staying stuck at the pre-crash `true`.
      refute Serving.ready?()
    end)
  end

  test "a warmup that fails once then succeeds retries and ends readiness at true" do
    counter = start_supervised!({Agent, fn -> 0 end})

    warmup_fun = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          :error

        _ ->
          :persistent_term.put({Serving, :ready?}, true)
          :ok
      end
    end

    capture_log(fn ->
      # base/max_backoff_ms shrunk from production's 1s/60s so the test
      # doesn't wait out a real backoff window; max_attempts is unrelated to
      # this test but harmless to shrink too.
      start_supervised!(
        {Warmer, warmup_fun: warmup_fun, base_backoff_ms: 2, max_backoff_ms: 5, max_attempts: 5}
      )

      wait_until(fn -> Serving.ready?() end)
    end)

    assert Serving.ready?()
    # exactly 2: the first (failing) attempt from handle_continue, then the
    # one scheduled retry that succeeds — proves the retry actually fired
    # rather than readiness coincidentally already being true.
    assert Agent.get(counter, & &1) == 2
  end

  test "max-attempts exhaustion logs an error and stops retrying" do
    counter = start_supervised!({Agent, fn -> 0 end})
    warmup_fun = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) && :error end

    log =
      capture_log(fn ->
        start_supervised!(
          {Warmer, warmup_fun: warmup_fun, base_backoff_ms: 2, max_backoff_ms: 5, max_attempts: 3}
        )

        wait_until(fn -> Agent.get(counter, & &1) >= 3 end)
        # give an (incorrect) further retry a chance to fire, so the exact
        # count assertion below can actually catch it if backoff didn't stop.
        Process.sleep(30)
      end)

    assert Agent.get(counter, & &1) == 3
    assert log =~ "failed after 3/3 attempts"
    refute Serving.ready?()
  end

  # Generic condition poll, mirroring wait_for_new_pid/3 below but for an
  # arbitrary predicate instead of a specific pid change.
  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(5)
        wait_until(fun, deadline)
      end
    end
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
