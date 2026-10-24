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

    test "allowed_languages/0 is the mainstream code set plus elixir" do
      assert "python" in TSI.allowed_languages()
      assert "elixir" in TSI.allowed_languages()
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

  # Real tree-sitter parsing loads the NIF and needs cached grammars; excluded by
  # default (see test_helper.exs). CI prefetches and runs it; locally run
  # `mix test --include tree_sitter`.
  describe "real AST chunking" do
    @describetag :tree_sitter

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

  describe "real AST chunking: elixir" do
    @describetag :tree_sitter

    test "chunks def/defp/defmacro/defdelegate at module-scoped boundaries" do
      src = """
      defmodule Payment.Processor do
        def process(order) do
          helper(order)
        end

        defp helper(o), do: o

        defmacro mymacro(x) do
          quote do
            unquote(x)
          end
        end

        defdelegate size(list), to: Enum, as: :count
      end
      """

      {:ok, chunks} = TSI.chunk(src, "elixir")

      crumbs = Enum.map(chunks, & &1.breadcrumb)
      assert "Payment.Processor > process" in crumbs
      assert "Payment.Processor > helper" in crumbs
      assert "Payment.Processor > mymacro" in crumbs
      assert "Payment.Processor > size" in crumbs
      assert Enum.all?(chunks, &(&1.parse_status == :ok))
    end

    test "names guard clauses and zero-arity no-paren defs, and nests modules" do
      src = """
      defmodule Outer do
        defmodule Inner do
          def zero, do: 0
          def guarded(x) when is_integer(x), do: x
        end
      end
      """

      {:ok, chunks} = TSI.chunk(src, "elixir")

      assert chunks |> Enum.map(& &1.breadcrumb) |> Enum.sort() ==
               ["Outer > Inner > guarded", "Outer > Inner > zero"]
    end

    test "canonicalises Elixir.-rooted module names and names defimpl by its protocol" do
      src = """
      defmodule Elixir.Rooted do
        def a, do: 1
      end

      defimpl Sized, for: Thing do
        def size(_), do: 0
      end
      """

      {:ok, chunks} = TSI.chunk(src, "elixir")

      crumbs = Enum.map(chunks, & &1.breadcrumb)
      assert "Rooted > a" in crumbs
      assert "Sized > size" in crumbs
    end

    test "a module-less top-level def (script) still chunks" do
      {:ok, chunks} = TSI.chunk("def top(x) do\n  x + 1\nend\n", "elixir")

      assert Enum.map(chunks, & &1.breadcrumb) == ["top"]
    end

    test "chunk_with_graph/2 yields the same chunks plus entities and call references" do
      src = """
      defmodule Pay do
        def run(x), do: helper(x)
        defp helper(x), do: x
      end
      """

      {:ok, chunks} = TSI.chunk(src, "elixir")

      assert {:ok, %{chunks: ^chunks, entities: entities, references: references}} =
               TSI.chunk_with_graph(src, "elixir")

      assert Enum.any?(entities, &(&1.qualified_name == "Pay" and &1.kind == :module))
      assert Enum.any?(entities, &(&1.qualified_name == "Pay.run" and &1.kind == :function))
      assert Enum.any?(references, &(&1.kind == :call and &1.name == "helper"))
    end
  end

  describe "chunk_with_graph/2 (single parse, two consumers)" do
    @describetag :tree_sitter

    test "returns the same chunks as chunk/2 on the same source, plus non-empty graph lists" do
      src =
        "class Bar:\n    def m(self):\n        return helper()\n\ndef helper():\n    return 1\n"

      {:ok, chunks} = TSI.chunk(src, "python")

      {:ok, %{chunks: graph_chunks, entities: entities, references: references}} =
        TSI.chunk_with_graph(src, "python")

      assert graph_chunks == chunks
      assert Enum.any?(entities, &(&1.qualified_name == "Bar.m" and &1.kind == :method))
      assert Enum.any?(entities, &(&1.qualified_name == "helper" and &1.kind == :function))

      assert Enum.any?(
               references,
               &(&1.kind == :call and &1.name == "helper" and &1.from == "Bar.m")
             )
    end

    test "propagates pre-flight guard errors same as chunk/2" do
      assert {:error, :unsupported_language} = TSI.chunk_with_graph("x = 1", "cobol")
      assert {:error, :binary_content} = TSI.chunk_with_graph("ok\x00bad", "python")
    end

    test "dispatched through Chunking.chunk_with_graph/2 when TreeSitterImpl is configured" do
      prev = Application.get_env(:retrieval_node, :chunking_impl)
      Application.put_env(:retrieval_node, :chunking_impl, TSI)
      on_exit(fn -> Application.put_env(:retrieval_node, :chunking_impl, prev) end)

      src = "def top():\n    return 1\n"

      assert {:ok, %{chunks: chunks, entities: entities, references: []}} =
               RetrievalNode.Chunking.chunk_with_graph(src, "python")

      assert Enum.any?(chunks, &(&1.breadcrumb == "top"))
      assert Enum.any?(entities, &(&1.qualified_name == "top" and &1.kind == :function))
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
