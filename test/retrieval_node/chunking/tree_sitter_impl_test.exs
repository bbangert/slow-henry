defmodule RetrievalNode.Chunking.TreeSitterImplTest do
  # The "guarded/1 without the supervisor running" describe below terminates
  # and restarts the real, application-owned RetrievalNode.ChunkTaskSupervisor
  # — a global supervision-tree mutation that would race any other async test
  # relying on that supervisor being up. async: false for the whole module
  # rather than splitting it out, to keep this file simple.
  use ExUnit.Case, async: false

  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  describe "pre-flight guards (NIF-free — reject before reaching the parser)" do
    test "rejects a file over the size cap" do
      big = String.duplicate("x\n", 1_100_000)
      assert {:error, :too_large} = TSI.chunk(big, "python")
    end

    test "rejects binary content (null byte)" do
      assert {:error, :binary_content} = TSI.chunk("ok\x00bad", "python")
    end

    test "rejects a language not in the allowlist" do
      assert {:error, :unsupported_language} = TSI.chunk("x = 1", "cobol")
    end

    test "allowed_languages/0 is the mainstream code set" do
      assert "python" in TSI.allowed_languages()
      refute "elixir" in TSI.allowed_languages()
    end
  end

  describe "guarded/1 (NIF-free — the crash/timeout isolation wrapper)" do
    # The crash/exit tests intentionally raise/exit inside the supervised Task,
    # which the Task.Supervisor logs; capture it to keep test output clean.
    @describetag capture_log: true

    # RetrievalNode.ChunkTaskSupervisor is started by the application tree
    # (lib/retrieval_node/application.ex) — no test-local start needed.

    test "passes through an {:ok, chunks} result" do
      assert {:ok, [:a, :b]} = TSI.guarded(fn -> {:ok, [:a, :b]} end)
    end

    test "passes through an {:error, reason} result" do
      assert {:error, :nope} = TSI.guarded(fn -> {:error, :nope} end)
    end

    test "a raising parse becomes {:error, {:chunk_crashed, _}} — never kills the caller" do
      assert {:error, {:chunk_crashed, _reason}} = TSI.guarded(fn -> raise "boom" end)
      # The caller survives and can still do work — a regression to a linked
      # `async` would have killed this process before reaching here.
      assert {:ok, [:still_working]} = TSI.guarded(fn -> {:ok, [:still_working]} end)
    end

    test "an exiting parse becomes {:error, {:chunk_crashed, _}}" do
      assert {:error, {:chunk_crashed, _}} = TSI.guarded(fn -> exit(:kaboom) end)
    end

    test "a hanging parse times out to {:error, :chunk_timeout}" do
      # call_timeout_ms is 100 in test config; sleeping past it triggers shutdown.
      assert {:error, :chunk_timeout} = TSI.guarded(fn -> Process.sleep(5_000) end)
    end
  end

  # Real tree-sitter parsing loads the NIF; excluded by default to keep the suite
  # NIF-free. Run with `mix test --include integration`.
  describe "real AST chunking" do
    @describetag :integration

    # RetrievalNode.ChunkTaskSupervisor is started by the application tree
    # (lib/retrieval_node/application.ex) — no test-local start needed.

    test "chunks python at function/method boundaries with scoped breadcrumbs" do
      src = "def top():\n    return 1\n\nclass Bar:\n    def m(self):\n        return 2\n"
      {:ok, chunks} = TSI.chunk(src, "python")

      crumbs = Enum.map(chunks, & &1.breadcrumb)
      assert "top" in crumbs
      assert "Bar > m" in crumbs
      assert Enum.all?(chunks, &(&1.parse_status == :ok))
    end

    test "a class emits its methods (not a duplicate whole-class chunk)" do
      src = "class A:\n    def one(self):\n        pass\n    def two(self):\n        pass\n"
      {:ok, chunks} = TSI.chunk(src, "python")

      assert Enum.map(chunks, & &1.breadcrumb) |> Enum.sort() == ["A > one", "A > two"]
    end

    test "chunks javascript functions and class methods" do
      src = "function foo() { return 1 }\nclass A { bar() { return 2 } }\n"
      {:ok, chunks} = TSI.chunk(src, "javascript")

      crumbs = Enum.map(chunks, & &1.breadcrumb)
      assert "foo" in crumbs
      assert "A > bar" in crumbs
      assert Enum.all?(chunks, &(&1.parse_status == :ok))
    end
  end

  # The application tree owns RetrievalNode.ChunkTaskSupervisor, so this test
  # deliberately terminates that child for its duration (restoring it via
  # on_exit) to verify guarded/1 fails closed rather than crashing the caller
  # when the supervisor is absent. This is exactly why the module is
  # async: false — any concurrently running test that hit `guarded/1` while
  # the supervisor was torn down would fail closed for an unrelated reason.
  describe "guarded/1 without the supervisor running" do
    setup do
      :ok =
        Supervisor.terminate_child(RetrievalNode.Supervisor, RetrievalNode.ChunkTaskSupervisor)

      on_exit(fn ->
        Supervisor.restart_child(RetrievalNode.Supervisor, RetrievalNode.ChunkTaskSupervisor)
      end)

      :ok
    end

    test "returns {:error, :chunk_supervisor_down} instead of crashing" do
      refute Process.whereis(RetrievalNode.ChunkTaskSupervisor)
      assert {:error, :chunk_supervisor_down} = TSI.guarded(fn -> {:ok, []} end)
      assert Process.alive?(self())
    end
  end
end
