defmodule RetrievalNode.GraphTest do
  # async: false — the batch-size tests mutate Application env.
  use RetrievalNode.DataCase, async: false

  import ExUnit.CaptureLog

  alias RetrievalNode.Graph
  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  setup do
    %{source: source_fixture()}
  end

  defp source_fixture do
    id = "acme/app-#{System.unique_integer([:positive])}"
    Repo.insert!(%Source{source_type: :git_repo, name: id, identifier: id})
  end

  defp chunk_fixture(source, chunk_key) do
    Repo.get_by(Chunk, source_id: source.id, chunk_key: chunk_key) ||
      Repo.insert!(%Chunk{
        source_id: source.id,
        source_type: :git_repo,
        chunk_key: chunk_key,
        content_hash: "h-#{System.unique_integer([:positive])}",
        content: "content",
        context_breadcrumb: chunk_key,
        metadata: %{}
      })
  end

  defp def_(name, kind \\ :function), do: %{qualified_name: name, kind: kind, line: 1}
  defp call(name, from), do: %{name: name, kind: :call, from: from, line: 2}
  defp import_(name, from \\ nil), do: %{name: name, kind: :import, from: from, line: 1}

  defp graph(entities, references), do: %{entities: entities, references: references}

  defp staged(source, chunk_key, graph, opts \\ []) do
    path = Keyword.get(opts, :path, "app.py")

    %{
      source_id: source.id,
      lang: Keyword.get(opts, :lang, "python"),
      chunk_key: chunk_key,
      natural_key: "repo:acme/app:#{path}",
      metadata: %{"path" => path},
      graph: graph
    }
  end

  # Creates the chunk row for every staged row (as the ingest write would) and
  # runs the upsert with the resulting key -> id map.
  defp upsert(source, rows) do
    ids = Map.new(rows, &{&1.chunk_key, chunk_fixture(source, &1.chunk_key).id})
    Graph.upsert_from_staged(Repo, rows, ids)
  end

  defp entities_by_name, do: Entity |> Repo.all() |> Map.new(&{&1.qualified_name, &1})

  describe "upsert_from_staged/3" do
    test "an empty batch is a no-op" do
      assert {:ok, %{entities: 0, mentions: 0, edges: 0}} =
               Graph.upsert_from_staged(Repo, [], %{})
    end

    test "entities, mentions, and edges land (def kind wins, weight aggregates)", %{
      source: source
    } do
      rows = [
        staged(
          source,
          "c1",
          graph([def_("a")], [call("b", "a"), call("b", "a"), import_("os")])
        ),
        staged(source, "c2", graph([def_("b")], []))
      ]

      assert {:ok, %{entities: 3, mentions: 5, edges: 1}} = upsert(source, rows)

      assert %{"a" => a, "b" => b, "os" => os} = entities_by_name()
      assert a.kind == :function
      assert a.path == "app.py"
      assert a.language == "python"
      assert a.source_id == source.id
      assert os.kind == :module
      assert os.path == nil

      # Both calls to "b" share a chunk, so they collapse into one mention.
      mentions = Repo.all(EntityMention)
      assert length(mentions) == 4
      assert Enum.count(mentions, &(&1.kind == :definition)) == 2
      assert Enum.count(mentions, &(&1.kind == :call)) == 1
      assert Enum.count(mentions, &(&1.kind == :import)) == 1

      assert [edge] = Repo.all(EntityEdge)
      assert edge.kind == :calls
      assert edge.weight == 2
      assert edge.source_entity_id == a.id
      assert edge.target_entity_id == b.id
      assert edge.chunk_id == chunk_fixture(source, "c1").id
    end

    test "an import with a `from` becomes an :imports edge", %{source: source} do
      assert {:ok, %{edges: 1}} =
               upsert(source, [staged(source, "c1", graph([def_("a")], [import_("os", "a")]))])

      assert [%EntityEdge{kind: :imports}] = Repo.all(EntityEdge)
    end

    test "path falls back to natural_key when metadata has no path", %{source: source} do
      row = %{staged(source, "c1", graph([def_("a")], [])) | metadata: nil}
      assert {:ok, _} = upsert(source, [row])
      assert %{path: "repo:acme/app:app.py"} = entities_by_name()["a"]
    end

    test "nil, empty, and one-key graphs are accepted", %{source: source} do
      rows = [
        staged(source, "c1", nil),
        staged(source, "c2", %{}),
        staged(source, "c3", %{entities: [def_("only_def")]}),
        staged(source, "c4", %{references: [call("only_ref", nil)]})
      ]

      assert {:ok, %{entities: 2, mentions: 2, edges: 0}} = upsert(source, rows)
    end

    test "rows with a nil lang and no graph data pass through", %{source: source} do
      assert {:ok, %{entities: 0}} =
               upsert(source, [staged(source, "c1", nil, lang: nil)])
    end

    test "a row whose chunk_key has no chunk id is skipped", %{source: source} do
      row = staged(source, "missing", graph([def_("a")], [call("b", "a")]))

      assert {:ok, %{entities: 2, mentions: 0, edges: 0}} =
               Graph.upsert_from_staged(Repo, [row], %{})
    end

    test "the same definition twice in one batch (multi-clause function) upserts once", %{
      source: source
    } do
      clause = def_("Billing.charge")

      rows = [
        staged(
          source,
          "c1",
          graph([def_("Billing", :module), clause, clause, clause], [
            call("log", "Billing.charge")
          ])
        ),
        staged(source, "c2", graph([clause], []))
      ]

      assert {:ok, %{entities: entities}} = upsert(source, rows)
      # Billing, Billing.charge, log
      assert entities == 3
      assert Repo.aggregate(Entity, :count, :id) == 3

      # Re-running against the now-existing rows hits ON CONFLICT DO UPDATE.
      assert {:ok, _} = upsert(source, rows)
      assert Repo.aggregate(Entity, :count, :id) == 3
    end

    test "re-running on equivalent data is idempotent (no doubled weight/mentions)", %{
      source: source
    } do
      rows = [
        staged(source, "c1", graph([def_("a")], [call("b", "a")])),
        staged(source, "c2", graph([def_("b")], []))
      ]

      upsert(source, rows)
      counts = {count(Entity), count(EntityMention), count(EntityEdge)}
      weight = Repo.one!(EntityEdge).weight

      upsert(source, rows)

      assert {count(Entity), count(EntityMention), count(EntityEdge)} == counts
      assert Repo.one!(EntityEdge).weight == weight
    end

    test "a batch spanning two sources raises", %{source: source} do
      other = source_fixture()

      rows = [
        staged(source, "c1", graph([def_("a")], [])),
        staged(other, "c2", graph([def_("b")], []))
      ]

      assert_raise ArgumentError, ~r/source_id/, fn -> upsert(source, rows) end
    end

    test "graph-bearing rows with different languages raise", %{source: source} do
      rows = [
        staged(source, "c1", graph([def_("a")], []), lang: "python"),
        staged(source, "c2", graph([def_("b")], []), lang: "ruby")
      ]

      assert_raise ArgumentError, ~r/language/, fn -> upsert(source, rows) end
    end
  end

  describe "re-chunk staleness" do
    test "a re-ingest that drops one call and adds another re-derives mentions and edges", %{
      source: source
    } do
      upsert(source, [staged(source, "c1", graph([def_("a")], [call("old", "a")]))])
      upsert(source, [staged(source, "c1", graph([def_("a")], [call("new", "a")]))])

      %{"a" => a, "old" => old, "new" => new} = entities_by_name()

      call_mentions = Repo.all(from m in EntityMention, where: m.kind == :call)
      assert [%{entity_id: new_id}] = call_mentions
      assert new_id == new.id
      refute Enum.any?(call_mentions, &(&1.entity_id == old.id))

      assert [edge] = Repo.all(EntityEdge)
      assert {edge.source_entity_id, edge.target_entity_id} == {a.id, new.id}
    end

    test "a definition that drops ALL its calls sheds its stale outgoing edge", %{source: source} do
      upsert(source, [staged(source, "c1", graph([def_("a")], [call("b", "a")]))])
      assert count(EntityEdge) == 1

      upsert(source, [staged(source, "c1", graph([def_("a")], []))])
      assert count(EntityEdge) == 0
    end
  end

  describe "chunk-level edge provenance" do
    test "two files defining the same entity each keep their own outgoing edge", %{source: source} do
      f1 = staged(source, "f1", graph([def_("shared")], [call("x", "shared")]), path: "f1.py")
      f2 = staged(source, "f2", graph([def_("shared")], [call("y", "shared")]), path: "f2.py")

      upsert(source, [f1])
      upsert(source, [f2])

      %{"shared" => shared, "x" => x, "y" => y} = entities_by_name()

      targets = Repo.all(EntityEdge) |> Enum.map(& &1.target_entity_id) |> Enum.sort()
      assert targets == Enum.sort([x.id, y.id])
      assert Enum.all?(Repo.all(EntityEdge), &(&1.source_entity_id == shared.id))
    end

    test "re-ingesting file A with a changed call leaves file B's edge alone", %{source: source} do
      a1 = staged(source, "fa", graph([def_("shared")], [call("x", "shared")]), path: "a.py")
      b = staged(source, "fb", graph([def_("shared")], [call("y", "shared")]), path: "b.py")
      upsert(source, [a1])
      upsert(source, [b])

      a2 = staged(source, "fa", graph([def_("shared")], [call("z", "shared")]), path: "a.py")
      upsert(source, [a2])

      names =
        Repo.all(
          from e in EntityEdge,
            join: t in Entity,
            on: t.id == e.target_entity_id,
            select: t.qualified_name
        )

      assert Enum.sort(names) == ["y", "z"]
    end

    test "a legacy NULL-chunk_id edge on a batch definition entity is removed on re-ingest", %{
      source: source
    } do
      row = staged(source, "c1", graph([def_("shared")], [call("x", "shared")]))
      upsert(source, [row])

      shared = entities_by_name()["shared"]

      legacy_target =
        Repo.insert!(%Entity{
          source_id: source.id,
          language: "python",
          qualified_name: "legacy_target",
          kind: :function
        })

      legacy_edge =
        Repo.insert!(%EntityEdge{
          source_entity_id: shared.id,
          target_entity_id: legacy_target.id,
          kind: :calls
        })

      assert is_nil(legacy_edge.chunk_id)

      upsert(source, [row])
      refute Repo.get(EntityEdge, legacy_edge.id)
    end
  end

  describe "reference-only entities" do
    test "never clobber an existing definition's kind/path", %{source: source} do
      upsert(source, [
        staged(source, "c1", graph([def_("Mod.run", :method)], []), path: "mod.py")
      ])

      upsert(source, [staged(source, "c2", graph([], [call("Mod.run", nil)]), path: "other.py")])

      assert %{kind: :method, path: "mod.py"} = entities_by_name()["Mod.run"]
      assert count(Entity) == 1
      assert Repo.aggregate(from(m in EntityMention, where: m.kind == :call), :count, :id) == 1
    end
  end

  describe "language-scoped entity binding" do
    test "a same-named entity in another language is never bound to by a python file", %{
      source: source
    } do
      js =
        Repo.insert!(%Entity{
          source_id: source.id,
          language: "javascript",
          qualified_name: "setup",
          kind: :function
        })

      assert {:ok, _} =
               upsert(source, [
                 staged(source, "c1", graph([def_("setup")], [call("helper", "setup")]))
               ])

      py = Repo.get_by!(Entity, source_id: source.id, language: "python", qualified_name: "setup")
      refute py.id == js.id

      assert Repo.all(from m in EntityMention, where: m.entity_id == ^js.id) == []
      assert [edge] = Repo.all(EntityEdge)
      assert edge.source_entity_id == py.id
    end
  end

  describe "graph sanitation" do
    test "oversized names are dropped with a warning; the rest persist", %{source: source} do
      long = String.duplicate("x", 3_000)

      row =
        staged(
          source,
          "c1",
          graph([def_("a"), def_(long)], [call(long, "a"), call("b", "a")])
        )

      log = capture_log(fn -> assert {:ok, _} = upsert(source, [row]) end)

      assert log =~ "graph symbol"
      names = Repo.all(from e in Entity, select: e.qualified_name)
      assert "a" in names and "b" in names
      refute Enum.any?(names, &(byte_size(&1) > 256))
    end

    test "malformed elements are dropped without raising; valid siblings persist", %{
      source: source
    } do
      row =
        staged(
          source,
          "c1",
          graph(
            [
              def_("a"),
              %{qualified_name: nil, kind: :function},
              "bare string",
              %{kind: :function}
            ],
            [
              %{kind: :call, from: "a"},
              %{name: "b", kind: nil, from: "a"},
              %{name: "c", kind: "call", from: "a"},
              call("d", "a")
            ]
          )
        )

      log = capture_log(fn -> assert {:ok, _} = upsert(source, [row]) end)

      assert log =~ "graph symbol"
      assert entities_by_name() |> Map.keys() |> Enum.sort() == ["a", "d"]
    end

    test "non-list and non-map containers are dropped without raising", %{source: source} do
      rows = [
        staged(source, "c1", %{entities: nil, references: "oops"}),
        staged(source, "c2", %{entities: %{}, references: [call("b", nil)]}),
        staged(source, "c3", "not a map")
      ]

      log = capture_log(fn -> assert {:ok, %{entities: 1}} = upsert(source, rows) end)

      assert log =~ "graph symbol"
      assert Map.keys(entities_by_name()) == ["b"]
    end
  end

  describe "kind catch-alls" do
    test "an unknown reference kind raises ArgumentError", %{source: source} do
      row = staged(source, "c1", graph([], [%{name: "mystery", kind: :eval, from: nil}]))
      assert_raise ArgumentError, ~r/eval/, fn -> upsert(source, [row]) end
    end

    test "an unknown entity kind raises ArgumentError", %{source: source} do
      row = staged(source, "c1", graph([%{qualified_name: "a", kind: :macro}], []))
      assert_raise ArgumentError, ~r/macro/, fn -> upsert(source, [row]) end
    end
  end

  describe "insert batch size" do
    test "a non-positive :graph_insert_batch_size raises ArgumentError", %{source: source} do
      Application.put_env(:retrieval_node, :graph_insert_batch_size, 0)
      on_exit(fn -> Application.delete_env(:retrieval_node, :graph_insert_batch_size) end)

      assert_raise ArgumentError, ~r/batch_size/, fn ->
        upsert(source, [staged(source, "c1", graph([def_("a")], []))])
      end
    end

    test "a small batch size still writes every row", %{source: source} do
      Application.put_env(:retrieval_node, :graph_insert_batch_size, 2)
      on_exit(fn -> Application.delete_env(:retrieval_node, :graph_insert_batch_size) end)

      defs = for n <- 1..5, do: def_("f#{n}")

      assert {:ok, %{entities: 5, mentions: 5}} =
               upsert(source, [staged(source, "c1", graph(defs, []))])

      assert count(Entity) == 5
    end
  end

  describe "gc_orphaned_entities/1" do
    defp seed_entity(source, qualified_name) do
      Repo.insert!(%Entity{
        source_id: source.id,
        language: "python",
        qualified_name: qualified_name,
        kind: :function
      })
    end

    defp seed_edge(source_entity, target_entity) do
      Repo.insert!(%EntityEdge{
        source_entity_id: source_entity.id,
        target_entity_id: target_entity.id,
        kind: :calls
      })
    end

    test "deleting a file's chunks cascades mentions but strands the entities", %{source: source} do
      upsert(source, [staged(source, "c1", graph([def_("a")], [call("b", "a")]))])

      Repo.delete_all(from c in Chunk, where: c.source_id == ^source.id)

      assert count(EntityMention) == 0
      assert count(Entity) == 2
      assert Graph.gc_orphaned_entities(source_id: source.id) == 2
      assert count(Entity) == 0
    end

    test "deletes zero-mention entities, cascades their edges, and spares mentioned ones", %{
      source: source
    } do
      upsert(source, [staged(source, "c1", graph([def_("kept")], []))])
      kept = entities_by_name()["kept"]

      orphan_a = seed_entity(source, "orphan_a")
      orphan_b = seed_entity(source, "orphan_b")
      seed_edge(orphan_a, orphan_b)
      seed_edge(kept, orphan_a)

      assert Graph.gc_orphaned_entities(source_id: source.id) == 2

      assert Repo.all(from e in Entity, select: e.qualified_name) == ["kept"]
      assert Repo.all(EntityEdge) == []
    end

    test "loops across batches: batch_size 1 with 3 orphans deletes all 3", %{source: source} do
      for n <- 1..3, do: seed_entity(source, "orphan_#{n}")

      assert Graph.gc_orphaned_entities(batch_size: 1, source_id: source.id) == 3
      assert Repo.aggregate(from(e in Entity, where: e.source_id == ^source.id), :count, :id) == 0
    end

    test "a non-positive batch_size raises ArgumentError" do
      for bad <- [0, -5] do
        assert_raise ArgumentError, ~r/batch_size/, fn ->
          Graph.gc_orphaned_entities(batch_size: bad)
        end
      end
    end

    test "source_id: scopes the sweep to one source", %{source: source} do
      other = source_fixture()
      seed_entity(source, "orphan_here")
      seed_entity(other, "orphan_there")

      assert Graph.gc_orphaned_entities(source_id: source.id) == 1
      assert Repo.all(from e in Entity, select: e.qualified_name) == ["orphan_there"]
    end
  end

  defp count(schema), do: Repo.aggregate(schema, :count, :id)
end
