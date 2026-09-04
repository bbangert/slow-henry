defmodule RetrievalNode.GraphTest do
  # async: false — shares the SQL sandbox with the (manual-mode) Oban instance
  # that the application tree starts (same reason as Ingest.PipelineTest).
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Graph
  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Ingest.{FileIngest, PendingChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev)
      Application.delete_env(:retrieval_node, :fake_chunk_result)
      Application.delete_env(:retrieval_node, :fake_chunk_with_graph_result)
    end)

    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    %{source: source}
  end

  defp seed_raw(source, content, natural_key \\ "repo:acme/app:app.py", path \\ "app.py") do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: natural_key,
          content_hash: "rawhash-#{System.unique_integer([:positive])}",
          raw_content: content,
          metadata: %{"path" => path}
        }
      ])

    Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
  end

  defp run_pipeline(raw) do
    assert {:ok, _summary} = FileIngest.apply(raw, [])
  end

  defp force_chunk(result), do: Application.put_env(:retrieval_node, :fake_chunk_result, result)

  defp force_chunk_with_graph(result),
    do: Application.put_env(:retrieval_node, :fake_chunk_with_graph_result, result)

  # Two chunks: chunk 0 (lines 1-2) defines "a" and calls "b"; also a
  # top-level import at line 0 that falls outside every chunk's range.
  # Chunk 1 (lines 4-5) defines "b".
  defp two_chunk_result do
    {:ok,
     %{
       chunks: [
         %{
           text: "def a():\n    return b()\n",
           breadcrumb: "a",
           start_line: 1,
           end_line: 2,
           kind: "function_definition",
           parse_status: :ok
         },
         %{
           text: "def b():\n    return 1\n",
           breadcrumb: "b",
           start_line: 4,
           end_line: 5,
           kind: "function_definition",
           parse_status: :ok
         }
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

  describe "per-chunk graph attachment" do
    test "entities/references land on the chunk whose line range contains them; the unmatched import lands on the first chunk",
         %{source: source} do
      force_chunk_with_graph(two_chunk_result())
      raw = seed_raw(source, "def a():\n    return b()\n\n\ndef b():\n    return 1\n")

      run_pipeline(raw)

      [chunk_a, chunk_b] =
        Chunk
        |> where([c], c.source_id == ^source.id)
        |> order_by([c], asc: c.context_breadcrumb)
        |> Repo.all()

      # breadcrumb "app.py > a" sorts before "app.py > b", matching chunk order.
      a_entity = Repo.get_by!(Entity, source_id: source.id, qualified_name: "a")
      b_entity = Repo.get_by!(Entity, source_id: source.id, qualified_name: "b")
      os_entity = Repo.get_by!(Entity, source_id: source.id, qualified_name: "os")

      mentions_for = fn chunk ->
        EntityMention
        |> where([m], m.chunk_id == ^chunk.id)
        |> Repo.all()
        |> Enum.map(&{&1.entity_id, &1.kind})
        |> MapSet.new()
      end

      # chunk_a: definition of "a", a call to "b", and the unmatched "os"
      # import (attaches to the first chunk).
      assert mentions_for.(chunk_a) ==
               MapSet.new([
                 {a_entity.id, :definition},
                 {b_entity.id, :call},
                 {os_entity.id, :import}
               ])

      # chunk_b: definition of "b" only.
      assert mentions_for.(chunk_b) == MapSet.new([{b_entity.id, :definition}])
    end

    test "the heuristic fallback path attaches no graph (no entities/mentions)", %{
      source: source
    } do
      force_chunk({:error, :unsupported_language})
      raw = seed_raw(source, "def a():\n    return 1\n\ndef b():\n    return 2\n")

      assert {:ok, summary} = FileIngest.apply(raw, [])
      assert summary.graph == %{entities: 0, mentions: 0, edges: 0}

      persisted = Repo.all(from c in Chunk, where: c.source_id == ^source.id)
      assert persisted != []
      assert Enum.all?(persisted, &(&1.parse_status == :heuristic_fallback))
      assert Repo.aggregate(Entity, :count, :id) == 0
      assert Repo.aggregate(EntityMention, :count, :id) == 0
    end
  end

  describe "oversized graph symbol sanitation" do
    # Consumer-side twin of the extractor's @max_symbol_bytes cap: rows staged
    # before the cap shipped (or by another producer) must be dropped with a
    # warning, not fail the entities unique-index insert and discard the job.
    test "oversized entity/reference names are dropped with a warning; the rest persist", %{
      source: source
    } do
      import ExUnit.CaptureLog

      long = String.duplicate("x", 3_000)

      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "def a():\n    return 1\n",
               breadcrumb: "a",
               start_line: 1,
               end_line: 2,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [
             %{qualified_name: "a", kind: :function, line: 1},
             %{qualified_name: long, kind: :function, line: 1}
           ],
           references: [
             %{name: long, kind: :call, from: "a", line: 2},
             %{name: "b", kind: :call, from: "a", line: 2}
           ]
         }}
      )

      raw = seed_raw(source, "def a():\n    return 1\n")

      log =
        capture_log(fn ->
          assert {:ok, _summary} = FileIngest.apply(raw, [])
        end)

      assert log =~ "graph symbol"

      names = Repo.all(from e in Entity, select: e.qualified_name)
      assert "a" in names
      assert "b" in names
      refute Enum.any?(names, &(byte_size(&1) > 256))
    end

    test "malformed shapes (nil name, a bare string element, a reference missing its name key) are dropped with a warning; valid siblings persist and nothing raises",
         %{source: source} do
      import ExUnit.CaptureLog

      staged_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "irrelevant-chunk-key",
        natural_key: "nk-malformed",
        metadata: %{"path" => "a.py"},
        graph: %{
          "entities" => [
            %{"qualified_name" => "a", "kind" => "function"},
            %{"qualified_name" => nil, "kind" => "function"},
            "not-a-map"
          ],
          "references" => [
            %{"name" => "b", "kind" => "call", "from" => "a"},
            %{"kind" => "call", "from" => "a"}
          ]
        }
      }

      log =
        capture_log(fn ->
          assert {:ok, _counts} = Graph.upsert_from_staged(Repo, [staged_row], %{})
        end)

      assert log =~ "graph symbol"

      names = Repo.all(from e in Entity, select: e.qualified_name)
      assert Enum.sort(names) == ["a", "b"]
    end

    test "a non-list entities container, a nil references container, a missing kind, and a non-binary kind are all dropped without raising; valid siblings persist",
         %{source: source} do
      import ExUnit.CaptureLog

      # Row 1 — container-shape drops: "entities" present but not a list,
      # "references" present but nil. Both containers are treated as empty
      # (counted as one dropped container each) instead of raising on
      # Enum.filter/length.
      container_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "shape-chunk-container",
        natural_key: "nk-shape-container",
        metadata: %{"path" => "container.py"},
        graph: %{
          "entities" => "not-a-list",
          "references" => nil
        }
      }

      # Row 2 — element kind-shape drops: an entity missing "kind" entirely,
      # and a reference whose "kind" is a non-binary (123). Both survive the
      # name check but must still be dropped by the kind gate, not raise
      # downstream in kind_atom/3 (KeyError/FunctionClauseError).
      kind_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "shape-chunk-kind",
        natural_key: "nk-shape-kind",
        metadata: %{"path" => "kind.py"},
        graph: %{
          "entities" => [
            %{"qualified_name" => "valid_entity", "kind" => "function"},
            %{"qualified_name" => "no_kind_entity"}
          ],
          "references" => [
            %{"name" => "valid_ref", "kind" => "call", "from" => "valid_entity"},
            %{"name" => "bad_kind_ref", "kind" => 123, "from" => "valid_entity"}
          ]
        }
      }

      log =
        capture_log(fn ->
          assert {:ok, _counts} =
                   Graph.upsert_from_staged(Repo, [container_row, kind_row], %{})
        end)

      assert log =~ "graph symbol"

      names = Repo.all(from e in Entity, select: e.qualified_name)
      assert "valid_entity" in names
      assert "valid_ref" in names
      refute "no_kind_entity" in names
      refute "bad_kind_ref" in names
    end
  end

  describe "full pipeline persistence" do
    test "entities, mentions, and edges land correctly (def kind wins, weight aggregates)", %{
      source: source
    } do
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "def a():\n    b()\n    b()\n",
               breadcrumb: "a",
               start_line: 1,
               end_line: 3,
               kind: "function_definition",
               parse_status: :ok
             },
             %{
               text: "def b():\n    return 1\n",
               breadcrumb: "b",
               start_line: 5,
               end_line: 6,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [
             %{qualified_name: "a", kind: :function, line: 1},
             %{qualified_name: "b", kind: :function, line: 5}
           ],
           references: [
             %{name: "b", kind: :call, from: "a", line: 2},
             %{name: "b", kind: :call, from: "a", line: 3},
             %{name: "os", kind: :import, from: nil, line: 0}
           ]
         }}
      )

      raw = seed_raw(source, "def a():\n    b()\n    b()\n\ndef b():\n    return 1\n")
      run_pipeline(raw)

      assert Repo.aggregate(Chunk, :count, :id) == 2

      entities = Entity |> Repo.all() |> Map.new(&{&1.qualified_name, &1})
      assert %{"a" => a, "b" => b, "os" => os} = entities
      assert a.kind == :function
      assert b.kind == :function
      # "os" is only ever seen as an import, never defined — reference-only.
      assert os.kind == :module
      assert os.path == nil

      # Both calls to "b" land in the same chunk, so they collapse into ONE
      # entity_mentions row (unique on entity_id/chunk_id/kind) — the edge
      # weight below is what carries the "called twice" signal instead.
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
    end

    test "re-running the pipeline on equivalent staged data is idempotent (no doubled weight/mentions)",
         %{source: source} do
      force_chunk_with_graph(two_chunk_result())
      content = "def a():\n    return b()\n\n\ndef b():\n    return 1\n"

      run_pipeline(seed_raw(source, content))

      entities_1 = Repo.aggregate(Entity, :count, :id)
      mentions_1 = Repo.aggregate(EntityMention, :count, :id)
      edges_1 = Repo.aggregate(EntityEdge, :count, :id)
      weight_1 = Repo.one!(EntityEdge).weight

      run_pipeline(seed_raw(source, content))

      assert Repo.aggregate(Entity, :count, :id) == entities_1
      assert Repo.aggregate(EntityMention, :count, :id) == mentions_1
      assert Repo.aggregate(EntityEdge, :count, :id) == edges_1
      assert Repo.one!(EntityEdge).weight == weight_1
    end
  end

  describe "re-chunk staleness" do
    defp rechunk_result(callee) do
      {:ok,
       %{
         chunks: [
           %{
             text: "def a():\n    #{callee}()\n",
             breadcrumb: "a",
             start_line: 1,
             end_line: 2,
             kind: "function_definition",
             parse_status: :ok
           }
         ],
         entities: [%{qualified_name: "a", kind: :function, line: 1}],
         references: [%{name: callee, kind: :call, from: "a", line: 2}]
       }}
    end

    test "a re-ingested file that drops one call and adds another re-derives mentions and edges",
         %{source: source} do
      natural_key = "repo:acme/app:staleness.py"

      force_chunk_with_graph(rechunk_result("b"))
      run_pipeline(seed_raw(source, "def a():\n    b()\n", natural_key))

      entities = Entity |> Repo.all() |> Map.new(&{&1.qualified_name, &1})
      entity_a = entities["a"]
      entity_b = entities["b"]

      assert [%{kind: :call}] =
               Repo.all(from m in EntityMention, where: m.entity_id == ^entity_b.id)

      assert %{target_entity_id: target_id} =
               Repo.one!(from e in EntityEdge, where: e.source_entity_id == ^entity_a.id)

      assert target_id == entity_b.id

      force_chunk_with_graph(rechunk_result("c"))
      run_pipeline(seed_raw(source, "def a():\n    c()\n", natural_key))

      entity_c = Repo.get_by!(Entity, qualified_name: "c")

      # the old call mention to "b" is gone
      assert Repo.all(from m in EntityMention, where: m.entity_id == ^entity_b.id) == []

      # the new call mention to "c" is present, on the same chunk row
      assert [%{kind: :call}] =
               Repo.all(from m in EntityMention, where: m.entity_id == ^entity_c.id)

      # the edge is re-derived: a -> c, not a -> b
      assert %{target_entity_id: new_target_id} =
               Repo.one!(from e in EntityEdge, where: e.source_entity_id == ^entity_a.id)

      assert new_target_id == entity_c.id
    end

    test "a re-ingested file whose definition drops ALL its calls sheds its stale outgoing edge",
         %{source: source} do
      natural_key = "repo:acme/app:staleness-empty.py"

      force_chunk_with_graph(rechunk_result("b"))
      run_pipeline(seed_raw(source, "def a():\n    b()\n", natural_key))

      entities = Entity |> Repo.all() |> Map.new(&{&1.qualified_name, &1})
      entity_a = entities["a"]
      entity_b = entities["b"]

      assert Repo.aggregate(EntityEdge, :count, :id) == 1

      # Re-ingest the same natural_key with a new aggregate that has NO
      # references at all — the empty-aggregate case that the old
      # aggregated-only delete scope skipped entirely, leaving the stale
      # a -> b edge behind forever.
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "def a():\n    return 1\n",
               breadcrumb: "a",
               start_line: 1,
               end_line: 2,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [%{qualified_name: "a", kind: :function, line: 1}],
           references: []
         }}
      )

      run_pipeline(seed_raw(source, "def a():\n    return 1\n", natural_key))

      # the stale a -> b edge is gone
      assert Repo.all(from e in EntityEdge, where: e.source_entity_id == ^entity_a.id) == []

      # entities and mentions are otherwise correct: "a" still exists with a
      # definition mention, and "b" (no longer called or defined) survives as
      # a now-orphaned entity untouched by this batch.
      assert Repo.get!(Entity, entity_a.id)
      assert Repo.get!(Entity, entity_b.id)

      assert [%{kind: :definition}] =
               Repo.all(from m in EntityMention, where: m.entity_id == ^entity_a.id)
    end
  end

  describe "chunk-level edge provenance" do
    # A single-chunk file whose one definition calls one callee — enough to
    # drive an outgoing edge from a merged entity for the tests below.
    defp calling_result(caller_name, callee_name) do
      {:ok,
       %{
         chunks: [
           %{
             text: "def #{caller_name}():\n    #{callee_name}()\n",
             breadcrumb: caller_name,
             start_line: 1,
             end_line: 2,
             kind: "function_definition",
             parse_status: :ok
           }
         ],
         entities: [%{qualified_name: caller_name, kind: :function, line: 1}],
         references: [%{name: callee_name, kind: :call, from: caller_name, line: 2}]
       }}
    end

    defp outgoing_targets(source_entity) do
      EntityEdge
      |> where([e], e.source_entity_id == ^source_entity.id)
      |> Repo.all()
      |> Enum.map(& &1.target_entity_id)
      |> Enum.sort()
    end

    test "two files in one source defining the same merged entity each keep their own outgoing edge — neither file's ingest clobbers the other's",
         %{source: source} do
      force_chunk_with_graph(calling_result("shared", "x"))

      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file1.py", "file1.py")
      )

      force_chunk_with_graph(calling_result("shared", "y"))

      run_pipeline(
        seed_raw(source, "def shared():\n    y()\n", "repo:acme/app:file2.py", "file2.py")
      )

      # only ONE "shared" entity exists — entity identity merges across
      # files of a source (same source_id/language/qualified_name).
      assert [shared] = Repo.all(from e in Entity, where: e.qualified_name == "shared")

      entities = Entity |> Repo.all() |> Map.new(&{&1.qualified_name, &1})
      x = entities["x"]
      y = entities["y"]

      # Pre-fix, file2's ingest would delete every outgoing edge of
      # "shared" (file-wide re-derivation) before writing its own, wiping
      # out file1's x-edge. With chunk-level provenance, both contributions
      # survive as their own rows.
      assert outgoing_targets(shared) == Enum.sort([x.id, y.id])
    end

    test "re-ingesting file A with a changed call updates only A's contribution; file B's edge survives",
         %{source: source} do
      force_chunk_with_graph(calling_result("shared", "x"))

      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file1.py", "file1.py")
      )

      force_chunk_with_graph(calling_result("shared", "y"))

      run_pipeline(
        seed_raw(source, "def shared():\n    y()\n", "repo:acme/app:file2.py", "file2.py")
      )

      [shared] = Repo.all(from e in Entity, where: e.qualified_name == "shared")
      y = Repo.get_by!(Entity, qualified_name: "y")

      # Re-ingest file1 (same natural_key/chunk_key) with a different callee.
      force_chunk_with_graph(calling_result("shared", "z"))

      run_pipeline(
        seed_raw(source, "def shared():\n    z()\n", "repo:acme/app:file1.py", "file1.py")
      )

      z = Repo.get_by!(Entity, qualified_name: "z")

      assert outgoing_targets(shared) == Enum.sort([y.id, z.id])
    end

    test "read-side aggregation: the same logical edge contributed by two chunks sums into one weighted result",
         %{source: source} do
      force_chunk_with_graph(calling_result("shared", "x"))

      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file1.py", "file1.py")
      )

      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file2.py", "file2.py")
      )

      [shared] = Repo.all(from e in Entity, where: e.qualified_name == "shared")
      x = Repo.get_by!(Entity, qualified_name: "x")

      # Two chunk-scoped rows back this one logical edge...
      assert Repo.aggregate(
               from(e in EntityEdge, where: e.source_entity_id == ^shared.id),
               :count,
               :id
             ) == 2

      # ...but the read path (Graph.related_entities/3) sums them into a
      # single logical edge instead of surfacing two separate rows.
      assert [%{entity: found, weight: 2, hop: 1}] =
               Graph.related_entities([shared.id], :callees, 1)

      assert found.id == x.id
    end

    test "a legacy NULL-chunk_id edge on a batch definition entity is removed by the transitional delete on re-ingest",
         %{source: source} do
      force_chunk_with_graph(calling_result("shared", "x"))

      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file1.py", "file1.py")
      )

      [shared] = Repo.all(from e in Entity, where: e.qualified_name == "shared")

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

      # Re-ingest file1 — "shared" is a definition entity in this batch, so
      # the transitional `is_nil(chunk_id) and source_entity_id in
      # def_entity_ids` delete scope catches this pre-provenance row even
      # though it was never written by this batch's own chunk.
      run_pipeline(
        seed_raw(source, "def shared():\n    x()\n", "repo:acme/app:file1.py", "file1.py")
      )

      refute Repo.get(EntityEdge, legacy_edge.id)
    end
  end

  describe "reference-only entities never clobber a definition" do
    test "an existing definition's kind/path survive a later reference-only sighting", %{
      source: source
    } do
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "def helper():\n    return 1\n",
               breadcrumb: "helper",
               start_line: 1,
               end_line: 2,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [%{qualified_name: "helper", kind: :function, line: 1}],
           references: []
         }}
      )

      run_pipeline(
        seed_raw(
          source,
          "def helper():\n    return 1\n",
          "repo:acme/app:helper.py",
          "helper.py"
        )
      )

      # A bare import reference (never a call/definition) resolves to kind
      # :module with no path when it's the only sighting — the opposite of
      # what "helper" is already known to be, so this proves the guess loses.
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "helper()\n",
               breadcrumb: "",
               start_line: 1,
               end_line: 1,
               kind: "module",
               parse_status: :ok
             }
           ],
           entities: [],
           references: [%{name: "helper", kind: :import, from: nil, line: 1}]
         }}
      )

      run_pipeline(seed_raw(source, "helper()\n", "repo:acme/app:caller.py", "caller.py"))

      entity = Repo.get_by!(Entity, qualified_name: "helper")
      assert entity.kind == :function
      assert entity.path == "helper.py"
    end
  end

  describe "language-scoped entity binding" do
    test "a same-named entity in another language is never bound to by a python file's re-resolved mentions, even when it was inserted later (physically after) the python entity",
         %{source: source} do
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "def a():\n    setup()\n",
               breadcrumb: "a",
               start_line: 1,
               end_line: 2,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [%{qualified_name: "setup", kind: :function, line: 1}],
           references: [%{name: "setup", kind: :call, from: "a", line: 1}]
         }}
      )

      # 1) Run the pipeline for a python file that both defines and calls
      # "setup" — creates the python entity plus its definition + call
      # mentions, on chunk_key sha256("repo:acme/app:app.py|0|a").
      run_pipeline(seed_raw(source, "def a():\n    setup()\n"))

      python_setup =
        Repo.get_by!(Entity, source_id: source.id, language: "python", qualified_name: "setup")

      # 2) Insert the JS "setup" entity directly, AFTER the python one, so it
      # has the later (higher) physical insertion order. This is the crux of
      # the regression: the pre-fix resolve_entity_ids/4 filtered its
      # select-back only on source_id + qualified_name (no language), then
      # did Map.new/1 (last-wins) over whatever row order Postgres returned
      # for an unordered `SELECT ... WHERE qualified_name IN (...)`. For a
      # freshly-populated, never-updated table, a sequential scan
      # overwhelmingly returns rows in insertion (heap) order — python first,
      # js second here — so the pre-fix last-wins map would deterministically
      # pick the JS row. That's the best determinism a black-box test can
      # offer against an unordered SELECT: it's a strong probabilistic
      # argument from Postgres's actual scan behavior on a small, freshly
      # written table, not a guarantee enforced by the SQL standard.
      js_entity =
        Repo.insert!(%Entity{
          source_id: source.id,
          language: "javascript",
          qualified_name: "setup",
          kind: :function
        })

      # 3) Re-resolve "setup" for the SAME chunk from step 1, without
      # re-declaring the python entity — a staged row carrying only a NEW
      # reference (no "entities"), targeting the real chunk id via
      # chunk_ids_by_key, called directly against Graph.upsert_from_staged/3
      # (the same function Ingest.FileIngest's write step calls). This re-triggers
      # resolve_entity_ids/4 for "setup" with both rows now in the table,
      # WITHOUT upserting/touching the python row again: collect_definitions
      # is empty here, and the reference-only entity upsert for "setup" hits
      # on_conflict: :nothing against the pre-existing python row, leaving
      # its physical position exactly as step 1 left it (deliberately —
      # re-running the full pipeline instead would re-upsert the python
      # entity with on_conflict: {:replace, ...}, physically repositioning
      # its row tuple after the just-inserted js row and accidentally making
      # even the pre-fix seq-scan order favor python again, masking the bug).
      [chunk] = Repo.all(from c in Chunk, where: c.source_id == ^source.id)

      reresolve_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "reresolve-setup-chunk-key",
        natural_key: "nk-reresolve-setup",
        metadata: %{"path" => "app.py"},
        graph: %{
          "entities" => [],
          "references" => [%{"name" => "setup", "kind" => "call", "from" => "a"}]
        }
      }

      assert {:ok, _counts} =
               Graph.upsert_from_staged(Repo, [reresolve_row], %{
                 "reresolve-setup-chunk-key" => chunk.id
               })

      chunk_mentions = Repo.all(from m in EntityMention, where: m.chunk_id == ^chunk.id)

      assert chunk_mentions != []

      # every re-resolved mention of "setup" on this chunk binds to the
      # python entity —
      assert Enum.all?(chunk_mentions, &(&1.entity_id == python_setup.id))

      # — and the js entity, inserted later, has zero mentions.
      assert Repo.all(from m in EntityMention, where: m.entity_id == ^js_entity.id) == []
    end
  end

  describe "kind conversion catch-alls (LLM-extractor seam)" do
    test "an unknown reference kind raises ArgumentError instead of crashing with FunctionClauseError",
         %{source: source} do
      staged_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "irrelevant-chunk-key",
        natural_key: "nk",
        metadata: %{"path" => "a.py"},
        graph: %{
          "entities" => [],
          "references" => [%{"name" => "mystery", "kind" => "eval", "from" => nil}]
        }
      }

      assert_raise ArgumentError, ~r/eval/, fn ->
        Graph.upsert_from_staged(Repo, [staged_row], %{})
      end
    end

    test "TreeSitter's emittable entity kinds are all valid Entity.kind enum values" do
      # entity_kind_for/2 is private to Graph.Extractor.TreeSitter; this list
      # is pinned to its category -> kind mapping (:class_like -> :class,
      # :module_like -> :module, :function_like -> :method when the
      # enclosing container is :class_like, :function otherwise) — update
      # this list if that mapping ever changes.
      tree_sitter_entity_kinds = [:function, :method, :class, :module]

      assert Enum.all?(tree_sitter_entity_kinds, &(&1 in Ecto.Enum.values(Entity, :kind)))
    end
  end

  describe "insert_all_batched/4 batch size validation" do
    # insert_all_batched/4 has no batch_size argument of its own — every
    # call reads it via insert_batch_size/0's Application config lookup
    # (:graph_insert_batch_size, defaulting to @insert_batch_size). Nothing
    # in the public API exposes it as a per-call option the way
    # gc_orphaned_entities/1 exposes :batch_size, but ops/test config can
    # still set it to a bad value, and insert_batch_size/0 is the entry
    # point where that value enters the module — so it gets the same guard.
    # Without the guard, Enum.chunk_every/2 (what insert_all_batched/4 feeds
    # the configured size into) raises a bare FunctionClauseError on a
    # non-positive count rather than hanging — this pins the clearer
    # ArgumentError instead.
    test "a non-positive :graph_insert_batch_size raises ArgumentError instead of a bare FunctionClauseError",
         %{source: source} do
      Application.put_env(:retrieval_node, :graph_insert_batch_size, 0)
      on_exit(fn -> Application.delete_env(:retrieval_node, :graph_insert_batch_size) end)

      staged_row = %{
        source_id: source.id,
        lang: "python",
        chunk_key: "irrelevant-chunk-key",
        natural_key: "nk-batch-size",
        metadata: %{"path" => "a.py"},
        graph: %{
          "entities" => [%{"qualified_name" => "a", "kind" => "function"}],
          "references" => []
        }
      }

      assert_raise ArgumentError, ~r/batch_size/, fn ->
        Graph.upsert_from_staged(Repo, [staged_row], %{})
      end
    end
  end

  describe "gc_orphaned_entities/1" do
    # No locking (FOR UPDATE SKIP LOCKED + delete-time recheck) since
    # Ingest.SourceOwner became the single writer per source: there is no
    # concurrent process that could land a new mention on a candidate
    # between the select and the delete, so a plain "select candidate ids,
    # delete those ids" inside one transaction is the whole mechanism now.
    # The tests below cover the observable contract that mechanism must
    # preserve: an entity with a mention is never deleted, a zero-mention
    # entity is, batching exhausts every orphan across rounds, and
    # `source_id:` scopes the sweep to one source.
    defp seed_chunk(source, path, chunk_key) do
      Repo.insert!(%Chunk{
        source_id: source.id,
        source_type: :git_repo,
        chunk_key: chunk_key,
        content_hash: "h-#{chunk_key}",
        content: "content",
        context_breadcrumb: path,
        metadata: %{"path" => path}
      })
    end

    defp seed_entity(source, qualified_name) do
      Repo.insert!(%Entity{
        source_id: source.id,
        language: "python",
        qualified_name: qualified_name,
        kind: :function
      })
    end

    defp seed_mention(entity, chunk, kind) do
      Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: kind})
    end

    defp seed_edge(source_entity, target_entity, kind) do
      Repo.insert!(%EntityEdge{
        source_entity_id: source_entity.id,
        target_entity_id: target_entity.id,
        kind: kind
      })
    end

    # Mirrors RepoSync.delete_removed/2's path-based Repo.delete_all on Chunk —
    # the exact deletion the ingest pipeline runs on file removal.
    defp delete_chunks_by_path(source, path) do
      from(c in Chunk,
        where: c.source_id == ^source.id and fragment("?->>'path'", c.metadata) == ^path
      )
      |> Repo.delete_all()
    end

    test "the pipeline's path-based chunk deletion cascades mentions but strands the entity and its edges",
         %{source: source} do
      chunk = seed_chunk(source, "gone.py", "k1")
      entity_a = seed_entity(source, "a")
      entity_b = seed_entity(source, "b")
      seed_mention(entity_a, chunk, :definition)
      seed_edge(entity_a, entity_b, :calls)

      delete_chunks_by_path(source, "gone.py")

      # cascade via chunks -> entity_mentions FK
      assert Repo.all(EntityMention) == []
      # entities have no FK back to chunks — they survive, now at zero mentions
      assert Repo.aggregate(Entity, :count, :id) == 2
      # edges FK entities, not chunks — untouched by the chunk deletion
      assert Repo.aggregate(EntityEdge, :count, :id) == 1
    end

    test "deletes zero-mention entities, cascades their edges, and spares entities that still have mentions",
         %{source: source} do
      chunk = seed_chunk(source, "keep.py", "k2")
      kept_entity = seed_entity(source, "kept")
      seed_mention(kept_entity, chunk, :definition)

      orphan_a = seed_entity(source, "orphan_a")
      orphan_b = seed_entity(source, "orphan_b")
      seed_edge(orphan_a, orphan_b, :calls)
      seed_edge(kept_entity, orphan_a, :calls)

      assert Graph.gc_orphaned_entities() == 2

      assert Repo.all(from e in Entity, select: e.qualified_name) == ["kept"]
      # both edges touched an orphan entity on one end, so both die via FK cascade
      assert Repo.all(EntityEdge) == []
    end

    test "loops across batches: batch_size 1 with 3 orphans deletes all 3", %{source: source} do
      for n <- 1..3, do: seed_entity(source, "orphan_#{n}")

      assert Graph.gc_orphaned_entities(batch_size: 1) == 3
      assert Repo.aggregate(Entity, :count, :id) == 0
    end

    test "batch_size: 0 raises ArgumentError instead of recursing forever on an empty candidate batch" do
      assert_raise ArgumentError, ~r/batch_size/, fn ->
        Graph.gc_orphaned_entities(batch_size: 0)
      end
    end

    test "batch_size: -5 raises ArgumentError instead of recursing forever" do
      assert_raise ArgumentError, ~r/batch_size/, fn ->
        Graph.gc_orphaned_entities(batch_size: -5)
      end
    end

    test "source_id: scopes the sweep to one source, sparing another source's orphans", %{
      source: source
    } do
      other_source =
        Repo.insert!(%Source{source_type: :git_repo, name: "other", identifier: "acme/other"})

      seed_entity(source, "orphan_here")
      seed_entity(other_source, "orphan_there")

      assert Graph.gc_orphaned_entities(source_id: source.id) == 1

      assert Repo.all(from e in Entity, select: e.qualified_name) == ["orphan_there"]
    end
  end

  describe "find_entities/2" do
    defp seed_repo_chunk(source, path, chunk_key, repo) do
      Repo.insert!(%Chunk{
        source_id: source.id,
        source_type: :git_repo,
        repo: repo,
        chunk_key: chunk_key,
        content_hash: "h-#{chunk_key}",
        content: "content",
        context_breadcrumb: path,
        metadata: %{"path" => path}
      })
    end

    defp seed_lang_entity(source, qualified_name, language) do
      Repo.insert!(%Entity{
        source_id: source.id,
        language: language,
        qualified_name: qualified_name,
        kind: :function
      })
    end

    test "exact match short-circuits suffix and trigram tiers", %{source: source} do
      exact = seed_entity(source, "process")
      _suffix_candidate = seed_entity(source, "PaymentProcessor.process")

      assert [found] = Graph.find_entities("process", [])
      assert found.id == exact.id
    end

    test "suffix match fires only when no exact match exists", %{source: source} do
      suffix_match = seed_entity(source, "PaymentProcessor.process")

      assert [found] = Graph.find_entities("process", [])
      assert found.id == suffix_match.id
    end

    test "trigram fallback finds a near-miss when exact and suffix both find nothing", %{
      source: source
    } do
      typo_target = seed_entity(source, "process_payment")

      assert [found | _] = Graph.find_entities("process_paymnet", [])
      assert found.id == typo_target.id
    end

    test "an unmatched name returns an empty list", %{source: source} do
      _unrelated = seed_entity(source, "totally_unrelated_zzz")
      assert Graph.find_entities("qqqqqqqqqqqqqqqq", []) == []
    end

    test "suffix tier escapes LIKE metacharacters instead of treating them as wildcards", %{
      source: source
    } do
      _entity = seed_entity(source, "PaymentProcessor.process")

      # Unescaped, "%" as the suffix pattern's literal segment would still be
      # anchored by the "%." prefix we add, but a caller-supplied "_" or "\"
      # would silently act as a wildcard/escape char instead of matching
      # itself — proving escape_like/1 is applied. "%" alone also exercises
      # the corpus-walk failure scenario: it must find nothing, not
      # everything.
      assert Graph.find_entities("%", []) == []
    end

    test "repo filter scopes to entities mentioned in a chunk of that repo" do
      source_a = Repo.insert!(%Source{source_type: :git_repo, name: "a", identifier: "acme/a"})
      source_b = Repo.insert!(%Source{source_type: :git_repo, name: "b", identifier: "acme/b"})

      entity_a = seed_entity(source_a, "shared_name")
      entity_b = seed_entity(source_b, "shared_name")

      chunk_a = seed_repo_chunk(source_a, "a.py", "ka", "repo-a")
      chunk_b = seed_repo_chunk(source_b, "b.py", "kb", "repo-b")

      seed_mention(entity_a, chunk_a, :definition)
      seed_mention(entity_b, chunk_b, :definition)

      assert [found] = Graph.find_entities("shared_name", repo: "repo-a")
      assert found.id == entity_a.id
    end

    test "lang filter scopes to entities.language", %{source: source} do
      python_entity = seed_lang_entity(source, "shared_lang_name", "python")
      _elixir_entity = seed_lang_entity(source, "shared_lang_name", "elixir")

      assert [found] = Graph.find_entities("shared_lang_name", lang: "python")
      assert found.id == python_entity.id
    end

    test ":limit caps the result count and defaults/clamps sanely", %{source: source} do
      for n <- 1..5, do: seed_entity(source, "Widget.method_#{n}")

      assert length(Graph.find_entities("method_1", [])) == 1

      # suffix-tier trigram-adjacent names all share the "method_" prefix but
      # distinct suffixes, so only exact/suffix on a shared bare name exercises
      # :limit meaningfully; assert the option is honored without raising.
      assert Graph.find_entities("method_1", limit: 999) |> length() <= 50
    end
  end

  describe "related_entities/3" do
    defp seed_weighted_edge(source_entity, target_entity, kind, weight) do
      Repo.insert!(%EntityEdge{
        source_entity_id: source_entity.id,
        target_entity_id: target_entity.id,
        kind: kind,
        weight: weight
      })
    end

    test "callers: 1-hop, ordered by weight desc", %{source: source} do
      target = seed_entity(source, "target_fn")
      caller_a = seed_entity(source, "caller_a")
      caller_c = seed_entity(source, "caller_c")

      seed_weighted_edge(caller_a, target, :calls, 3)
      seed_weighted_edge(caller_c, target, :calls, 5)

      results = Graph.related_entities([target.id], :callers, 1)

      assert [%{entity: e1, weight: 5, hop: 1}, %{entity: e2, weight: 3, hop: 1}] = results
      assert e1.id == caller_c.id
      assert e2.id == caller_a.id
    end

    test "callees: 2-hop union excludes seeds and back-edges into a seed", %{source: source} do
      a = seed_entity(source, "a_fn")
      b = seed_entity(source, "b_fn")
      d = seed_entity(source, "d_fn")

      seed_weighted_edge(a, b, :calls, 2)
      seed_weighted_edge(b, d, :calls, 4)
      # cycle back to the seed — must never appear in results even though it's
      # a high-weight edge reachable at hop 2.
      seed_weighted_edge(b, a, :calls, 9)

      results = Graph.related_entities([a.id], :callees, 2)
      by_id = Map.new(results, &{&1.entity.id, &1})

      refute Map.has_key?(by_id, a.id)
      assert %{weight: 2, hop: 1} = by_id[b.id]
      assert %{weight: 4, hop: 2} = by_id[d.id]

      # weight ordering across hops: d (4) outranks b (2)
      assert Enum.map(results, & &1.entity.id) == [d.id, b.id]
    end

    test "dedup keeps the max weight when an entity is reached via multiple edges in the same hop",
         %{source: source} do
      a = seed_entity(source, "a2_fn")
      c = seed_entity(source, "c2_fn")
      target = seed_entity(source, "shared_target_fn")

      seed_weighted_edge(a, target, :calls, 2)
      seed_weighted_edge(c, target, :calls, 7)

      assert [%{entity: found, weight: 7, hop: 1}] =
               Graph.related_entities([a.id, c.id], :callees, 1)

      assert found.id == target.id
    end

    test "hop-2 frontier caps at the top 100 hop-1 entities by weight, dropping lower-weight ones' onward edges",
         %{source: source} do
      target = seed_entity(source, "hot_fn")

      # 101 hop-1 callers of target, weights 1..101 — 1 more than
      # @hop2_frontier_limit (100), so exactly one (the lowest-weight) must
      # be excluded from the hop-2 traversal frontier.
      callers =
        for i <- 1..101 do
          caller = seed_entity(source, "caller_#{i}")
          seed_weighted_edge(caller, target, :calls, i)
          caller
        end

      # weight 1 (the minimum) is the one that must be cut from the frontier.
      excluded_caller = Enum.at(callers, 0)
      # any of the other 100 (weight >= 2) must survive into the frontier.
      included_caller = Enum.at(callers, 1)

      unreachable = seed_entity(source, "unreachable_via_excluded_frontier")
      reachable = seed_entity(source, "reachable_via_included_frontier")

      # Weight 200 (higher than any hop-1 weight) so, IF traversed, this
      # hop-2 edge would easily survive the final @related_entities_limit
      # (50) cut — isolating the assertion to the hop-2 frontier cap itself,
      # not the separate final-result-count cap.
      seed_weighted_edge(unreachable, excluded_caller, :calls, 200)
      seed_weighted_edge(reachable, included_caller, :calls, 200)

      ids = Graph.related_entities([target.id], :callers, 2) |> Enum.map(& &1.entity.id)

      refute unreachable.id in ids
      assert reachable.id in ids
    end

    test "imports/importers traverse in opposite directions", %{source: source} do
      importer = seed_entity(source, "importer_mod")
      imported = seed_entity(source, "imported_mod")

      seed_edge(importer, imported, :imports)

      assert [%{entity: found_importer}] = Graph.related_entities([imported.id], :importers, 1)
      assert found_importer.id == importer.id

      assert [%{entity: found_imported}] = Graph.related_entities([importer.id], :imports, 1)
      assert found_imported.id == imported.id
    end

    test "a file-level import (from: nil, no entity_edges row) still resolves via import-mention",
         %{source: source} do
      force_chunk_with_graph(
        {:ok,
         %{
           chunks: [
             %{
               text: "import os\n\ndef a():\n    return 1\n",
               breadcrumb: "a",
               start_line: 1,
               end_line: 4,
               kind: "function_definition",
               parse_status: :ok
             }
           ],
           entities: [%{qualified_name: "a", kind: :function, line: 3}],
           references: [%{name: "os", kind: :import, from: nil, line: 1}]
         }}
      )

      run_pipeline(seed_raw(source, "import os\n\ndef a():\n    return 1\n"))

      entity_a = Repo.get_by!(Entity, qualified_name: "a")
      entity_os = Repo.get_by!(Entity, qualified_name: "os")

      # from: nil never resolves to a source_entity_id, so no edge exists —
      # proving the assertions below can only pass via mention-based
      # resolution, not the entity_edges leg.
      assert Repo.aggregate(EntityEdge, :count, :id) == 0

      assert [%{entity: found, hop: 1}] = Graph.related_entities([entity_os.id], :importers, 1)
      assert found.id == entity_a.id

      assert [%{entity: found, hop: 1}] = Graph.related_entities([entity_a.id], :imports, 1)
      assert found.id == entity_os.id
    end
  end

  describe "definition_snippets/2" do
    defp seed_content_chunk(source, path, chunk_key, content, extra) do
      Repo.insert!(
        struct(
          %Chunk{
            source_id: source.id,
            source_type: :git_repo,
            chunk_key: chunk_key,
            content_hash: "h-#{chunk_key}",
            content: content,
            context_breadcrumb: path,
            metadata: %{"path" => path}
          },
          extra
        )
      )
    end

    test "short content is returned unchanged, with provenance fields", %{source: source} do
      entity = seed_entity(source, "short_fn")

      chunk =
        seed_content_chunk(source, "short.py", "k-short", "def short_fn():\n    return 1\n",
          repo: "acme/app",
          lang: "python"
        )

      seed_mention(entity, chunk, :definition)

      assert [snippet] = Graph.definition_snippets([entity.id])
      assert snippet.entity_id == entity.id
      assert snippet.repo == "acme/app"
      assert snippet.lang == "python"
      assert snippet.path == "short.py"
      assert snippet.breadcrumb == "short.py"
      assert snippet.snippet == "def short_fn():\n    return 1\n"
    end

    test "content over 20 lines is truncated at 20 lines with a marker", %{source: source} do
      entity = seed_entity(source, "long_lines_fn")
      content = Enum.map_join(1..30, "\n", &"line #{&1}")

      chunk = seed_content_chunk(source, "long.py", "k-long", content, [])
      seed_mention(entity, chunk, :definition)

      assert [snippet] = Graph.definition_snippets([entity.id])
      assert String.ends_with?(snippet.snippet, "…")
      lines = snippet.snippet |> String.trim_trailing("…") |> String.split("\n")
      assert length(lines) == 20
      assert lines == Enum.map(1..20, &"line #{&1}")
    end

    test "content under 20 lines but over 1000 chars is truncated at 1000 chars with a marker", %{
      source: source
    } do
      entity = seed_entity(source, "long_chars_fn")
      long_line = String.duplicate("x", 600)
      content = "#{long_line}\n#{long_line}\n"

      chunk = seed_content_chunk(source, "wide.py", "k-wide", content, [])
      seed_mention(entity, chunk, :definition)

      assert [snippet] = Graph.definition_snippets([entity.id])
      assert String.ends_with?(snippet.snippet, "…")
      assert String.length(snippet.snippet) == 1001
    end

    test "an empty entity_ids list short-circuits to an empty list without querying" do
      assert Graph.definition_snippets([]) == []
    end
  end
end
