defmodule RetrievalNode.Ingest.GraphIngestTest do
  # async: false — mutates the :chunking_impl application env and runs
  # SourceOwner GenServers that share the SQL sandbox.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Chunking.{FakeImpl, LineGraphImpl, TreeSitterImpl}
  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Ingest.{FileIngest, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, FakeImpl)

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev)
      Application.delete_env(:retrieval_node, :fake_chunk_result)
      Application.delete_env(:retrieval_node, :fake_chunk_with_graph_result)
    end)

    %{source: source_fixture("acme/app")}
  end

  defp source_fixture(identifier) do
    Repo.insert!(%Source{source_type: :git_repo, name: identifier, identifier: identifier})
  end

  defp use_impl(impl), do: Application.put_env(:retrieval_node, :chunking_impl, impl)

  defp seed_raw(source, content, path, lang \\ "python") do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: source.identifier,
          lang: lang,
          natural_key: "repo:#{source.identifier}:#{path}",
          content_hash: "rawhash-#{System.unique_integer([:positive])}",
          raw_content: content,
          metadata: %{"path" => path}
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  defp seed_deletion(source, path) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          natural_key: "repo:#{source.identifier}:#{path}",
          metadata: %{"path" => path},
          status: "deleted"
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  defp chunks_for(source, path) do
    Chunk
    |> where([c], c.source_id == ^source.id)
    |> where([c], fragment("?->>'path'", c.metadata) == ^path)
    |> Repo.all()
  end

  defp mention_pairs(chunk) do
    EntityMention
    |> where([m], m.chunk_id == ^chunk.id)
    |> join(:inner, [m], e in Entity, on: e.id == m.entity_id)
    |> select([m, e], {e.qualified_name, m.kind})
    |> Repo.all()
    |> MapSet.new()
  end

  defp source_mention_count(source) do
    Repo.aggregate(
      from(m in EntityMention,
        join: c in Chunk,
        on: c.id == m.chunk_id,
        where: c.source_id == ^source.id
      ),
      :count,
      :id
    )
  end

  defp source_entity_names(source) do
    Repo.all(
      from e in Entity,
        where: e.source_id == ^source.id,
        select: e.qualified_name,
        order_by: e.qualified_name
    )
  end

  defp chunk_spec(text, crumb, start_line, end_line) do
    %{
      text: text,
      breadcrumb: crumb,
      start_line: start_line,
      end_line: end_line,
      kind: "function_definition",
      parse_status: :ok
    }
  end

  # Chunk 0 (lines 1-2) defines "a" and calls "b"; the import at line 0 falls
  # outside every chunk. Chunk 1 (lines 4-5) defines "b".
  defp two_chunk_result do
    {:ok,
     %{
       chunks: [
         chunk_spec("def a():\n    return b()\n", "a", 1, 2),
         chunk_spec("def b():\n    return 1\n", "b", 4, 5)
       ],
       entities: [
         %{qualified_name: "a", kind: :function, line: 1},
         %{qualified_name: "b", kind: :function, line: 4}
       ],
       references: [
         %{name: "b", kind: :call, from: "a", line: 2},
         %{name: "os", kind: :import, from: nil, line: 0}
       ]
     }}
  end

  defp force_graph(result),
    do: Application.put_env(:retrieval_node, :fake_chunk_with_graph_result, result)

  describe "per-chunk graph attachment (fake chunker)" do
    test "items land on the chunk containing their line; an outside import lands on the first chunk",
         %{source: source} do
      force_graph(two_chunk_result())
      raw = seed_raw(source, "def a():\n    return b()\n\n\ndef b():\n    return 1\n", "app.py")

      assert {:ok, %{action: :indexed, graph: %{entities: 3, mentions: 4}}} =
               FileIngest.apply(raw, [])

      [chunk_a, chunk_b] =
        Chunk
        |> where([c], c.source_id == ^source.id)
        |> order_by([c], asc: c.context_breadcrumb)
        |> Repo.all()

      assert mention_pairs(chunk_a) ==
               MapSet.new([{"a", :definition}, {"b", :call}, {"os", :import}])

      assert mention_pairs(chunk_b) == MapSet.new([{"b", :definition}])
    end

    test "heuristic fallback chunks carry no graph", %{source: source} do
      Application.put_env(:retrieval_node, :fake_chunk_result, {:error, :unsupported_language})
      raw = seed_raw(source, "def a():\n    return 1\n\ndef b():\n    return 2\n", "app.py")

      assert {:ok, summary} = FileIngest.apply(raw, [])
      assert summary.graph == %{entities: 0, mentions: 0, edges: 0}

      persisted = Repo.all(from c in Chunk, where: c.source_id == ^source.id)
      assert persisted != []
      assert Enum.all?(persisted, &(&1.parse_status == :heuristic_fallback))
      assert Repo.aggregate(Entity, :count, :id) == 0
      assert Repo.aggregate(EntityMention, :count, :id) == 0
    end

    test "rollback on graph failure: no chunk rows written, raw row survives", %{source: source} do
      # An unresolvable reference kind makes Graph.upsert_from_staged/3 raise
      # inside the write transaction, after the chunk insert.
      force_graph(
        {:ok,
         %{
           chunks: [chunk_spec("def f():\n    bogus()\n", "f", 1, 2)],
           entities: [],
           references: [%{name: "bogus", kind: :not_a_real_kind, from: "f", line: 1}]
         }}
      )

      raw = seed_raw(source, "v1", "badgraph.py")

      assert_raise ArgumentError, fn -> FileIngest.apply(raw, []) end
      assert chunks_for(source, "badgraph.py") == []
      assert Repo.aggregate(Entity, :count, :id) == 0
      assert Repo.get(PendingChunk, raw.id)
    end
  end

  describe "real tree-sitter (python, javascript) through FileIngest" do
    @describetag :tree_sitter

    setup do
      use_impl(TreeSitterImpl)
      :ok
    end

    @v1 "def helper():\n    return 1\n\ndef main():\n    return helper()\n"

    test "apply writes entities, mentions and edges in the same transaction", %{source: source} do
      raw = seed_raw(source, @v1, "app.py")

      assert {:ok, %{action: :indexed, graph: graph}} = FileIngest.apply(raw, [])
      assert graph.entities >= 2
      assert graph.mentions >= 3
      assert graph.edges >= 1

      assert source_entity_names(source) == ["helper", "main"]
      assert Repo.aggregate(EntityEdge, :count, :id) >= 1

      main_chunk = Enum.find(chunks_for(source, "app.py"), &(&1.content =~ "def main"))
      assert {"main", :definition} in mention_pairs(main_chunk)
      assert {"helper", :call} in mention_pairs(main_chunk)
    end

    test "re-applying an edited file replaces its mentions", %{source: source} do
      {:ok, _} = FileIngest.apply(seed_raw(source, @v1, "app.py"), [])

      v2 = "def helper():\n    return 1\n\ndef other():\n    return helper()\n"
      assert {:ok, %{action: :indexed}} = FileIngest.apply(seed_raw(source, v2, "app.py"), [])

      mentioned =
        Repo.all(
          from m in EntityMention,
            join: e in Entity,
            on: e.id == m.entity_id,
            join: c in Chunk,
            on: c.id == m.chunk_id,
            where: c.source_id == ^source.id,
            select: e.qualified_name,
            distinct: true,
            order_by: e.qualified_name
        )

      assert mentioned == ["helper", "other"]
    end

    test "a file with no definition boundaries still indexes (heuristic chunks) and keeps its import",
         %{source: source} do
      raw = seed_raw(source, "import os\nX = 1\n", "consts.py")

      assert {:ok, %{action: :indexed}} = FileIngest.apply(raw, [])

      [chunk] = chunks_for(source, "consts.py")
      assert chunk.parse_status == :heuristic_fallback
      assert mention_pairs(chunk) == MapSet.new([{"os", :import}])
    end

    test "a whitespace-only file still yields no chunks", %{source: source} do
      raw = seed_raw(source, "  \n\n", "blank.py")

      FileIngest.apply(raw, [])

      assert chunks_for(source, "blank.py") == []
      assert source_mention_count(source) == 0
    end

    test "two definitions on one line attach to their own chunks by byte position", %{
      source: source
    } do
      raw =
        seed_raw(source, "function a() {} function b() { target(); }\n", "ab.js", "javascript")

      assert {:ok, %{action: :indexed}} = FileIngest.apply(raw, [])

      [chunk_a, chunk_b] =
        source |> chunks_for("ab.js") |> Enum.sort_by(& &1.context_breadcrumb)

      assert mention_pairs(chunk_a) == MapSet.new([{"a", :definition}])
      assert mention_pairs(chunk_b) == MapSet.new([{"b", :definition}, {"target", :call}])
    end

    test "deleting the file removes its mentions via chunk cascade", %{source: source} do
      {:ok, _} = FileIngest.apply(seed_raw(source, @v1, "app.py"), [])
      assert source_mention_count(source) > 0

      assert {:ok, %{action: :deleted}} = FileIngest.apply(seed_deletion(source, "app.py"), [])
      assert chunks_for(source, "app.py") == []
      assert source_mention_count(source) == 0
    end
  end

  describe "SourceOwner graph GC (NIF-free line impl)" do
    setup %{source: source} do
      use_impl(LineGraphImpl)
      # on_exit runs in a separate process: capture the id, don't read the pdict.
      on_exit(fn -> SourceOwner.stop(source.id) end)
      :ok
    end

    test "gc/1 reaps orphans for that source only", %{source: source} do
      other = source_fixture("acme/other")
      for s <- [source, other], do: Repo.insert!(entity(s, "orphan"))
      on_exit(fn -> SourceOwner.stop(other.id) end)

      assert {:ok, 1} = SourceOwner.gc(source.id)
      assert source_entity_names(source) == []
      assert source_entity_names(other) == ["orphan"]
    end

    test "a pass that deletes a file reaps the entities it stranded", %{source: source} do
      seed_raw(source, "def gone():\n  1\n", "gone.py")
      assert {:ok, _} = SourceOwner.drain(source.id)
      assert source_entity_names(source) == ["gone"]

      seed_deletion(source, "gone.py")
      assert {:ok, _} = SourceOwner.drain(source.id)
      assert source_entity_names(source) == []
    end

    test "concurrent gc/1 calls never reap entities that ingest is attaching mentions to", %{
      source: source
    } do
      files = for n <- 1..12, do: "f#{n}.py"

      gc_tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            for _ <- 1..15 do
              assert {:ok, _} = SourceOwner.gc(source.id)
              Process.sleep(1)
            end
          end)
        end

      # Three generations of every file: each rewrite renames the file's
      # function, so the previous generation's entity is a real orphan that
      # GC (concurrent and post-pass) has work to do on.
      for gen <- 1..3 do
        for path <- files, do: seed_raw(source, "def #{fn_name(path, gen)}():\n  1\n", path)
        assert {:ok, _} = SourceOwner.drain(source.id)

        # Entities are only ever committed together with their mentions, so a
        # zero-mention entity can only be one GC has not yet reaped; the other
        # direction (a mentioned entity reaped) would show as a missing name.
        names = source_entity_names(source)
        assert Enum.all?(files, &(fn_name(&1, gen) in names))
      end

      Task.await_many(gc_tasks, 30_000)
      assert {:ok, _} = SourceOwner.gc(source.id)

      assert source_entity_names(source) == Enum.sort(Enum.map(files, &fn_name(&1, 3)))
      assert source_mention_count(source) == length(files)

      for path <- files do
        assert [chunk] = chunks_for(source, path)
        assert mention_pairs(chunk) == MapSet.new([{fn_name(path, 3), :definition}])
      end
    end
  end

  defp fn_name(path, gen), do: "fn_#{Path.rootname(path)}_g#{gen}"

  defp entity(source, name) do
    %Entity{source_id: source.id, language: "python", qualified_name: name, kind: :function}
  end
end
