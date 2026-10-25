defmodule RetrievalNode.GraphReadTest do
  # async: false — the FileIngest-backed tests mutate application env.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Chunking.FakeImpl
  alias RetrievalNode.Graph
  alias RetrievalNode.Graph.{Entity, EntityEdge}
  alias RetrievalNode.Ingest.{FileIngest, PendingChunks}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source}

  setup do
    %{source: source_fixture()}
  end

  defp source_fixture(repo \\ nil) do
    id = repo || "acme/app-#{System.unique_integer([:positive])}"
    Repo.insert!(%Source{source_type: :git_repo, name: id, identifier: id})
  end

  defp def_(name, kind \\ :function), do: %{qualified_name: name, kind: kind, line: 1}
  defp call(name, from), do: %{name: name, kind: :call, from: from, line: 2}
  defp import_(name, from \\ nil), do: %{name: name, kind: :import, from: from, line: 1}

  # Writes one chunk per spec through the real write path
  # (Graph.upsert_from_staged/3), so mentions/edges have exactly the shape
  # ingest produces. A spec is {chunk_key, entities, references, opts}.
  defp ingest(source, specs) do
    rows =
      for {key, entities, references, opts} <- specs do
        path = Keyword.get(opts, :path, "app.py")

        chunk =
          Repo.insert!(%Chunk{
            source_id: source.id,
            source_type: :git_repo,
            repo: Keyword.get(opts, :repo, source.identifier),
            lang: Keyword.get(opts, :lang, "python"),
            chunk_key: key,
            content_hash: "h-#{System.unique_integer([:positive])}",
            content: Keyword.get(opts, :content, "def #{key}(): pass"),
            context_breadcrumb: path,
            metadata: %{"path" => path}
          })

        {chunk,
         %{
           source_id: source.id,
           lang: Keyword.get(opts, :lang, "python"),
           chunk_key: key,
           natural_key: "repo:#{source.identifier}:#{path}",
           metadata: %{"path" => path},
           graph: %{entities: entities, references: references}
         }}
      end

    chunk_ids = Map.new(rows, fn {chunk, row} -> {row.chunk_key, chunk.id} end)
    {:ok, _} = Graph.upsert_from_staged(Repo, Enum.map(rows, &elem(&1, 1)), chunk_ids)
    Enum.map(rows, &elem(&1, 0))
  end

  defp entity!(source, name, lang \\ "python"),
    do: Repo.get_by!(Entity, source_id: source.id, qualified_name: name, language: lang)

  defp ids(entities), do: Enum.map(entities, & &1.id)
  defp related_ids(results), do: Enum.map(results, & &1.entity.id)

  describe "find_entities/2" do
    test "exact match short-circuits suffix and trigram tiers", %{source: source} do
      ingest(source, [{"c1", [def_("process"), def_("PaymentProcessor.process")], [], []}])

      assert [found] = Graph.find_entities("process")
      assert found.id == entity!(source, "process").id
    end

    test "suffix match fires only when no exact match exists", %{source: source} do
      ingest(source, [{"c1", [def_("PaymentProcessor.process")], [], []}])

      assert [found] = Graph.find_entities("process")
      assert found.qualified_name == "PaymentProcessor.process"
    end

    test "suffix results are ordered shortest-name-first", %{source: source} do
      ingest(source, [
        {"c1", [def_("A.B.shared"), def_("A.shared"), def_("Longer.Name.Here.shared")], [], []}
      ])

      assert Enum.map(Graph.find_entities("shared"), & &1.qualified_name) ==
               ["A.shared", "A.B.shared", "Longer.Name.Here.shared"]
    end

    test "trigram fallback finds a near-miss when exact and suffix find nothing", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("process_payment")], [], []}])

      assert [found | _] = Graph.find_entities("process_paymnet")
      assert found.id == entity!(source, "process_payment").id
    end

    test "an unmatched name returns an empty list", %{source: source} do
      ingest(source, [{"c1", [def_("totally_unrelated_zzz")], [], []}])
      assert Graph.find_entities("qqqqqqqqqqqqqqqq") == []
    end

    test "LIKE metacharacters in the name are literals, not wildcards", %{source: source} do
      ingest(source, [
        {"c1", [def_("Pay.process"), def_("Pay.p_ocess"), def_("Pay.pro%")], [], []}
      ])

      # Unescaped, "%" would match every dotted name and "_" any one char.
      assert Graph.find_entities("%") == []
      assert [one] = Graph.find_entities("p_ocess")
      assert one.qualified_name == "Pay.p_ocess"
      assert [pct] = Graph.find_entities("pro%")
      assert pct.qualified_name == "Pay.pro%"
      assert Graph.find_entities("\\") == []
    end

    test "names that can never match return [] instead of querying or raising", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("process")], [], []}])

      for bad <- ["", "   ", nil, 42, <<0>>, "pro\0cess", <<0xFF, 0xFE>>] do
        assert Graph.find_entities(bad) == []
      end

      assert Graph.find_entities("process", repo: <<0xFF>>) == []
      assert Graph.find_entities("process", lang: 5) == []
    end

    test "a name over the symbol byte cap returns [] even if a prefix would match", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("process")], [], []}])
      assert Graph.find_entities("process" <> String.duplicate("x", 300)) == []
      assert Graph.find_entities(String.duplicate("a", 257)) == []
    end

    test "repo filter scopes to entities mentioned in a chunk of that repo" do
      source_a = source_fixture("acme/a")
      source_b = source_fixture("acme/b")
      ingest(source_a, [{"ka", [def_("shared_name")], [], []}])
      ingest(source_b, [{"kb", [def_("shared_name")], [], []}])

      assert [found] = Graph.find_entities("shared_name", repo: "acme/a")
      assert found.source_id == source_a.id
      assert Graph.find_entities("shared_name", repo: "acme/none") == []
      assert length(Graph.find_entities("shared_name")) == 2
    end

    test "lang filter scopes to entities.language", %{source: source} do
      ingest(source, [{"c1", [def_("setup")], [], [lang: "python", path: "a.py"]}])
      ingest(source, [{"c2", [def_("setup")], [], [lang: "javascript", path: "a.js"]}])

      assert [found] = Graph.find_entities("setup", lang: "javascript")
      assert found.language == "javascript"
    end

    test ":limit defaults to 20, clamps to 50, and falls back on junk values", %{source: source} do
      defs = for n <- 1..60, do: def_("Mod#{n}.shared")
      ingest(source, [{"c1", defs, [], []}])

      assert length(Graph.find_entities("shared")) == 20
      assert length(Graph.find_entities("shared", limit: 999)) == 50
      assert length(Graph.find_entities("shared", limit: 3)) == 3

      for junk <- [0, -4, nil, "7", 2.5] do
        assert length(Graph.find_entities("shared", limit: junk)) == 20
      end

      # Same cut every time.
      assert ids(Graph.find_entities("shared", limit: 5)) ==
               ids(Graph.find_entities("shared", limit: 5))
    end

    test "the trigram tier honors the limit too", %{source: source} do
      defs = for n <- 1..60, do: def_("process_payment_#{n}")
      ingest(source, [{"c1", defs, [], []}])

      assert length(Graph.find_entities("process_paymnet", limit: 999)) <= 50
    end
  end

  describe "find_entities/2 defined_only" do
    # A reference-only entity (no :definition mention) is what the write path
    # creates for a call/import name it never saw defined.
    test "excludes reference-only entities in the exact tier" do
      a = source_fixture()
      b = source_fixture()
      ingest(a, [{"c1", [def_("tier_x")], [], []}])
      ingest(b, [{"c2", [def_("caller")], [call("tier_x", "caller")], []}])

      assert length(Graph.find_entities("tier_x")) == 2
      assert [found] = Graph.find_entities("tier_x", defined_only: true)
      assert found.source_id == a.id
    end

    test "falls through to the suffix tier past a reference-only exact match", %{source: source} do
      ingest(source, [
        {"c1", [def_("Pay.Processor.helper"), def_("caller")], [call("helper", "caller")], []}
      ])

      assert [%{qualified_name: "helper"}] = Graph.find_entities("helper")
      assert [found] = Graph.find_entities("helper", defined_only: true)
      assert found.qualified_name == "Pay.Processor.helper"
    end

    test "applies to the trigram tier too", %{source: source} do
      ingest(source, [
        {"c1", [def_("process_payment_now"), def_("caller")],
         [call("process_payment_nowx", "caller")], []}
      ])

      names = fn opts ->
        "process_paymnet_now" |> Graph.find_entities(opts) |> Enum.map(& &1.qualified_name)
      end

      assert "process_payment_nowx" in names.([])
      assert names.(defined_only: true) == ["process_payment_now"]
    end
  end

  describe "related_entities/3" do
    test "callers: 1-hop, ordered by weight desc (weights aggregate repeated calls)", %{
      source: source
    } do
      ingest(source, [
        {"c1", [def_("target"), def_("caller_a"), def_("caller_c")],
         [call("target", "caller_a")] ++
           List.duplicate(call("target", "caller_c"), 5) ++
           List.duplicate(call("target", "caller_a"), 2), []}
      ])

      results = Graph.related_entities([entity!(source, "target").id], :callers)

      assert [
               %{entity: %{qualified_name: "caller_c"}, weight: 5, hop: 1},
               %{entity: %{qualified_name: "caller_a"}, weight: 3, hop: 1}
             ] = results
    end

    test "a logical edge contributed by two chunks sums into one result", %{source: source} do
      ingest(source, [
        {"c1", [def_("target"), def_("caller")], [call("target", "caller")], [path: "a.py"]},
        {"c2", [def_("caller")], List.duplicate(call("target", "caller"), 2), [path: "b.py"]}
      ])

      assert [%{entity: %{qualified_name: "caller"}, weight: 3}] =
               Graph.related_entities([entity!(source, "target").id], :callers)
    end

    test "callees: 2-hop union excludes seeds and back-edges into a seed", %{source: source} do
      ingest(source, [
        {"c1", [def_("a"), def_("b"), def_("d")],
         List.duplicate(call("b", "a"), 2) ++
           List.duplicate(call("d", "b"), 4) ++ List.duplicate(call("a", "b"), 9), []}
      ])

      a = entity!(source, "a")
      results = Graph.related_entities([a.id], :callees, 2)
      by_name = Map.new(results, &{&1.entity.qualified_name, &1})

      refute Map.has_key?(by_name, "a")
      assert %{weight: 2, hop: 1} = by_name["b"]
      assert %{weight: 4, hop: 2} = by_name["d"]
      assert Enum.map(results, & &1.entity.qualified_name) == ["d", "b"]
    end

    test "dedup keeps the max weight when an entity is reached via several seeds", %{
      source: source
    } do
      ingest(source, [
        {"c1", [def_("a"), def_("c"), def_("shared_target")],
         List.duplicate(call("shared_target", "a"), 2) ++
           List.duplicate(call("shared_target", "c"), 7), []}
      ])

      seeds = [entity!(source, "a").id, entity!(source, "c").id]

      assert [%{entity: %{qualified_name: "shared_target"}, weight: 7, hop: 1}] =
               Graph.related_entities(seeds, :callees)
    end

    test "traversal never crosses sources even for same-named entities" do
      source_a = source_fixture("acme/a")
      source_b = source_fixture("acme/b")

      for {src, caller} <- [{source_a, "caller_a"}, {source_b, "caller_b"}] do
        ingest(src, [{"c1", [def_("util"), def_(caller)], [call("util", caller)], []}])
      end

      assert [%{entity: %{qualified_name: "caller_a"}}] =
               Graph.related_entities([entity!(source_a, "util").id], :callers, 2)
    end

    # Seen-entity rows must not consume the per-query fan-out slots. Built with
    # insert_all (not the write path) because exceeding @edge_fanout_limit (500)
    # via ingest would take 500+ distinct reference pairs; the limit is a
    # module attribute with no test seam.
    defp insert_calls(pairs) do
      now = DateTime.utc_now()

      rows =
        for {from, to, weight} <- pairs do
          %{
            source_entity_id: from,
            target_entity_id: to,
            kind: :calls,
            weight: weight,
            inserted_at: now,
            updated_at: now
          }
        end

      for batch <- Enum.chunk_every(rows, 1_000), do: Repo.insert_all(EntityEdge, batch)
    end

    defp dense_cluster(source, prefix, n) do
      ingest(source, [{"#{prefix}", for(i <- 1..n, do: def_("#{prefix}#{i}")), [], []}])
      for i <- 1..n, do: entity!(source, "#{prefix}#{i}").id
    end

    test "hop 1: edges among the seeds (more than the fan-out limit) don't hide a new entity",
         %{source: source} do
      seeds = dense_cluster(source, "s", 30)
      ingest(source, [{"n", [def_("fresh")], [], []}])
      fresh = entity!(source, "fresh").id

      # 30x30 = 900 seed->seed pairs (incl. self-loops), all heavier than the
      # one edge to the new entity.
      insert_calls(for(a <- seeds, b <- seeds, do: {a, b, 10}) ++ [{hd(seeds), fresh, 1}])

      assert [%{entity: %{id: ^fresh}, hop: 1}] = Graph.related_entities(seeds, :callees, 1)
    end

    test "hop 2: edges among seen entities (more than the fan-out limit) don't hide a new one",
         %{source: source} do
      [seed | rest] = dense_cluster(source, "h", 31)
      ingest(source, [{"n", [def_("fresh")], [], []}])
      fresh = entity!(source, "fresh").id

      insert_calls(
        for(h <- rest, do: {seed, h, 5}) ++
          for(a <- rest, b <- rest, do: {a, b, 10}) ++
          for(h <- rest, do: {h, seed, 10}) ++ [{hd(rest), fresh, 1}]
      )

      results = Graph.related_entities([seed], :callees, 2)
      assert %{hop: 2} = Enum.find(results, &(&1.entity.id == fresh))
    end

    test "results are capped at 50 and the cut is deterministic", %{source: source} do
      callers = for n <- 1..60, do: def_("caller_#{n}")
      refs = for n <- 1..60, do: call("target", "caller_#{n}")
      ingest(source, [{"c1", [def_("target") | callers], refs, []}])

      target = entity!(source, "target")
      first = Graph.related_entities([target.id], :callers, 2)

      assert length(first) == 50
      assert related_ids(first) == related_ids(Graph.related_entities([target.id], :callers, 2))
    end

    test "the hop-2 frontier is capped at the top 100 hop-1 entities by weight", %{
      source: source
    } do
      callers = for i <- 1..101, do: def_("caller_#{i}")
      refs = for i <- 1..101, _ <- 1..i, do: call("hot_fn", "caller_#{i}")

      extra = [
        def_("unreachable"),
        def_("reachable"),
        def_("hot_fn")
      ]

      # weight 200 > any hop-1 weight, so only the frontier cap can hide it.
      onward =
        List.duplicate(call("caller_1", "unreachable"), 200) ++
          List.duplicate(call("caller_2", "reachable"), 200)

      ingest(source, [{"c1", callers ++ extra, refs ++ onward, []}])

      ids = Graph.related_entities([entity!(source, "hot_fn").id], :callers, 2) |> related_ids()

      refute entity!(source, "unreachable").id in ids
      assert entity!(source, "reachable").id in ids
    end

    test "only the first 100 distinct seed ids are used; duplicates don't consume slots", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("target"), def_("caller")], [call("target", "caller")], []}])
      target = entity!(source, "target")

      filler = for _ <- 1..100, do: Ecto.UUID.generate()

      assert Graph.related_entities(filler ++ [target.id], :callers) == []

      assert [_] =
               Graph.related_entities(List.duplicate(target.id, 150) ++ filler, :callers)
    end

    test "empty seed list, unknown relation, and out-of-range hops", %{source: source} do
      assert Graph.related_entities([], :callers) == []

      ingest(source, [{"c1", [def_("a")], [], []}])
      id = entity!(source, "a").id

      for hops <- [0, 3, -1, nil, "1"] do
        assert_raise ArgumentError, fn -> Graph.related_entities([id], :callers, hops) end
      end

      for relation <- [:definitions, :bogus, "callers", nil] do
        assert_raise ArgumentError, fn -> Graph.related_entities([id], relation, 1) end
      end
    end

    test "imports/importers via an edge (import inside a definition scope)", %{source: source} do
      ingest(source, [
        {"c1", [def_("importer_fn")], [import_("imported_mod", "importer_fn")], []}
      ])

      importer = entity!(source, "importer_fn")
      imported = entity!(source, "imported_mod")

      assert [%{entity: found}] = Graph.related_entities([imported.id], :importers)
      assert found.id == importer.id
      assert [%{entity: found}] = Graph.related_entities([importer.id], :imports)
      assert found.id == imported.id
    end

    test "a file-level import (from: nil, no edge) resolves via import mentions", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("a")], [import_("os")], []}])

      a = entity!(source, "a")
      os = entity!(source, "os")
      assert Repo.aggregate(EntityEdge, :count, :id) == 0

      assert [%{entity: found, hop: 1, weight: 1}] = Graph.related_entities([os.id], :importers)
      assert found.id == a.id
      assert [%{entity: found}] = Graph.related_entities([a.id], :imports)
      assert found.id == os.id
    end

    test "a scoped import on a shared chunk is attributed only to its importing definition", %{
      source: source
    } do
      # A and B share a chunk; only B imports X (scoped, so it writes an
      # :imports edge AND an :import mention).
      ingest(source, [{"c1", [def_("a"), def_("b")], [import_("x", "b")], []}])

      a = entity!(source, "a")
      b = entity!(source, "b")
      x = entity!(source, "x")

      assert [%{entity: found}] = Graph.related_entities([x.id], :importers)
      assert found.id == b.id
      assert [%{entity: found}] = Graph.related_entities([b.id], :imports)
      assert found.id == x.id
      assert Graph.related_entities([a.id], :imports) == []
    end

    test "a file-level import is still found next to a scoped import on the same chunk", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("a"), def_("b")], [import_("os"), import_("x", "b")], []}])

      os = entity!(source, "os")
      names = Graph.related_entities([os.id], :importers) |> Enum.map(& &1.entity.qualified_name)
      assert Enum.sort(names) == ["a", "b"]
    end

    test "mention-leg weight is per (seed, result) pair, never summed across seeds", %{
      source: source
    } do
      ingest(source, [{"c1", [def_("a"), def_("b")], [import_("os")], []}])

      a = entity!(source, "a")
      b = entity!(source, "b")
      os_id = entity!(source, "os").id

      assert [%{entity: %{id: ^os_id}, weight: 1}] =
               Graph.related_entities([a.id, b.id], :imports)

      # mirror: two imported seeds sharing one importing definition
      ingest(source, [{"c2", [def_("d")], [import_("m1"), import_("m2")], []}])
      seeds = [entity!(source, "m1").id, entity!(source, "m2").id]

      assert [%{entity: %{qualified_name: "d"}, weight: 1}] =
               Graph.related_entities(seeds, :importers)
    end

    test "a file-level import through the real FileIngest pipeline resolves both ways" do
      prev = Application.get_env(:retrieval_node, :chunking_impl)
      Application.put_env(:retrieval_node, :chunking_impl, FakeImpl)

      on_exit(fn ->
        Application.put_env(:retrieval_node, :chunking_impl, prev)
        Application.delete_env(:retrieval_node, :fake_chunk_with_graph_result)
      end)

      Application.put_env(
        :retrieval_node,
        :fake_chunk_with_graph_result,
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

      source = source_fixture()

      {:ok, _} =
        PendingChunks.insert_raw_all([
          %{
            source: "git",
            source_id: source.id,
            source_type: "git_repo",
            repo: source.identifier,
            lang: "python",
            natural_key: "repo:#{source.identifier}:a.py",
            content_hash: "rawhash-#{System.unique_integer([:positive])}",
            raw_content: "import os\n\ndef a():\n    return 1\n",
            metadata: %{"path" => "a.py"}
          }
        ])

      raw = Repo.one!(from p in PendingChunk, order_by: [desc: p.id], limit: 1)
      assert {:ok, %{action: :indexed}} = FileIngest.apply(raw, [])

      a = entity!(source, "a")
      os = entity!(source, "os")

      assert [%{entity: found}] = Graph.related_entities([os.id], :importers)
      assert found.id == a.id
      assert [%{entity: found}] = Graph.related_entities([a.id], :imports)
      assert found.id == os.id
    end
  end

  describe "name aliasing (reference-only vs qualified definitions)" do
    # `helper` is called by its bare name, so the write path stores a
    # reference-only entity `helper` next to the definition
    # `Payment.Processor.helper`.
    setup %{source: source} do
      ingest(source, [
        {"c1",
         [def_("Payment.Processor.helper"), def_("Payment.Processor.process"), def_("leaf")],
         [call("helper", "Payment.Processor.process"), call("leaf", "Payment.Processor.helper")],
         []}
      ])

      %{
        helper_ref: entity!(source, "helper"),
        helper: entity!(source, "Payment.Processor.helper"),
        process: entity!(source, "Payment.Processor.process"),
        leaf: entity!(source, "leaf")
      }
    end

    defp names(results), do: results |> Enum.map(& &1.entity.qualified_name) |> Enum.sort()

    test "callees of the bare name resolve to the definition's callees", ctx do
      assert names(Graph.related_entities([ctx.helper_ref.id], :callees)) == ["leaf"]
    end

    test "callers of the qualified definition include callers of the bare name", ctx do
      assert names(Graph.related_entities([ctx.helper.id], :callers)) ==
               ["Payment.Processor.process"]
    end

    test "hop 2 callees: a reference-only hop-1 row is resolved before traversing on", ctx do
      results = Graph.related_entities([ctx.process.id], :callees, 2)

      assert %{entity: %{qualified_name: "helper"}, hop: 1} =
               Enum.find(results, &(&1.hop == 1))

      assert %{entity: %{qualified_name: "leaf"}, hop: 2} = Enum.find(results, &(&1.hop == 2))
    end

    test "hop 2 callers: the definition's callers via its alias", ctx do
      results = Graph.related_entities([ctx.leaf.id], :callers, 2)

      assert %{entity: %{qualified_name: "Payment.Processor.helper"}, hop: 1} =
               Enum.find(results, &(&1.hop == 1))

      assert %{entity: %{qualified_name: "Payment.Processor.process"}, hop: 2} =
               Enum.find(results, &(&1.hop == 2))
    end

    test "a bare name is attributed to every definition it aliases", %{source: source} do
      ingest(source, [
        {"c2", [def_("A.shared"), def_("B.shared"), def_("caller")], [call("shared", "caller")],
         []}
      ])

      for name <- ["A.shared", "B.shared"] do
        assert names(Graph.related_entities([entity!(source, name).id], :callers)) == ["caller"]
      end
    end

    test "aliasing stays within source and language", %{source: source, helper: helper} do
      other = source_fixture()
      ingest(other, [{"o1", [def_("Payment.Processor.helper")], [], []}])
      ingest(source, [{"c3", [def_("Payment.Processor.helper")], [], [lang: "javascript"]}])

      # control: this source's python definition does get the bare-name caller
      assert names(Graph.related_entities([helper.id], :callers)) ==
               ["Payment.Processor.process"]

      assert Graph.related_entities([entity!(other, "Payment.Processor.helper").id], :callers) ==
               []

      js = entity!(source, "Payment.Processor.helper", "javascript")
      assert Graph.related_entities([js.id], :callers) == []
    end

    test "a distinct definition named like a suffix of the seed is a real caller/callee", %{
      source: source
    } do
      ingest(source, [
        {"c8", [def_("Mod.run"), def_("run")], [call("Mod.run", "run"), call("run", "Mod.run")],
         []}
      ])

      mod_run = entity!(source, "Mod.run")
      run = entity!(source, "run")

      assert names(Graph.related_entities([mod_run.id], :callers)) == ["run"]
      assert names(Graph.related_entities([mod_run.id], :callees)) == ["run"]
      assert names(Graph.related_entities([run.id], :callers)) == ["Mod.run"]
    end

    test "an entity's own aliases are never returned as its results", %{source: source} do
      ingest(source, [
        {"c4", [def_("Mod.rec")], [call("rec", "Mod.rec")], []}
      ])

      rec = entity!(source, "Mod.rec")
      assert Graph.related_entities([rec.id], :callees, 2) == []
      assert Graph.related_entities([rec.id], :callers, 2) == []
    end

    # The expansion caps (@alias_limit = 500) are module attributes with no test
    # seam, so these build enough rows (800 / 600) to exceed them.
    test "callees: recursive aliases beyond the lookup cap are still excluded", %{source: source} do
      # 100 seeds, each calling all 8 of its own name suffixes (reference-only
      # aliases of itself): 800 alias entities > the 500-row lookup limit.
      prefix = "P.q.r.s.t.u.v"
      seeds = for i <- 1..100, do: "#{prefix}.fn#{i}"

      suffixes = fn name ->
        parts = String.split(name, ".")
        for n <- 1..length(parts), do: parts |> Enum.take(-n) |> Enum.join(".")
      end

      refs =
        for s <- seeds, suffix <- suffixes.(s), do: call(suffix, s)

      ingest(source, [
        {"c6", Enum.map(seeds, &def_/1) ++ [def_("real")], [call("real", hd(seeds)) | refs], []}
      ])

      ids = for s <- seeds, do: entity!(source, s).id

      assert [%{entity: %{qualified_name: "real"}}] = Graph.related_entities(ids, :callees)
    end

    test "callers of a bare name never return the definitions it aliases, past the cap", %{
      source: source
    } do
      defs = for i <- 1..600, do: def_("X#{i}.get")
      recursive = for i <- 1..600, do: call("get", "X#{i}.get")

      ingest(source, [
        {"c7", [def_("real_caller") | defs], [call("get", "real_caller") | recursive], []}
      ])

      results = Graph.related_entities([entity!(source, "get").id], :callers)
      assert names(results) == ["real_caller"]
    end

    test "resolving a hot bare name stays bounded", %{source: source} do
      defs = for i <- 1..600, do: def_("X#{i}.get")
      refs = for i <- 1..600, do: call("t#{i}", "X#{i}.get")
      ingest(source, [{"c5", defs ++ [def_("t0")], [call("get", "t0")] ++ refs, []}])

      get = entity!(source, "get")
      assert length(Graph.related_entities([get.id], :callees)) == 50
    end
  end

  describe "definition_snippets/2" do
    defp snippet_for(source, name, content, opts \\ []) do
      ingest(source, [{"k-#{name}", [def_(name)], [], [content: content] ++ opts}])
      [snippet] = Graph.definition_snippets([entity!(source, name).id])
      snippet
    end

    test "short content is returned unchanged, with provenance fields", %{source: source} do
      entity_content = "def short_fn():\n    return 1\n"
      snippet = snippet_for(source, "short_fn", entity_content, path: "short.py")

      assert snippet.entity_id == entity!(source, "short_fn").id
      assert snippet.repo == source.identifier
      assert snippet.lang == "python"
      assert snippet.path == "short.py"
      assert snippet.breadcrumb == "short.py"
      assert snippet.snippet == entity_content
    end

    test "content over 20 lines is cut at 20 lines with a marker", %{source: source} do
      content = Enum.map_join(1..30, "\n", &"line #{&1}")
      snippet = snippet_for(source, "many_lines", content)

      assert String.ends_with?(snippet.snippet, "…")

      assert snippet.snippet |> String.trim_trailing("…") |> String.split("\n") ==
               Enum.map(1..20, &"line #{&1}")
    end

    test "content over 1000 chars is cut at 1000 chars with a marker", %{source: source} do
      line = String.duplicate("x", 600)
      snippet = snippet_for(source, "wide", "#{line}\n#{line}\n")

      assert String.ends_with?(snippet.snippet, "…")
      assert String.length(snippet.snippet) == 1001
    end

    test "content exactly at the line and char caps is not marked truncated", %{source: source} do
      twenty = Enum.map_join(1..20, "\n", &"l#{&1}")
      assert snippet_for(source, "exact_lines", twenty).snippet == twenty

      thousand = String.duplicate("y", 1000)
      assert snippet_for(source, "exact_chars", thousand).snippet == thousand

      assert snippet_for(source, "one_over", thousand <> "y").snippet == thousand <> "…"
    end

    test "decomposed (combining-character) text is cut on code points and marked", %{
      source: source
    } do
      content = String.duplicate("e\u0301", 600)
      snippet = snippet_for(source, "combining", content)

      assert String.ends_with?(snippet.snippet, "…")
      assert snippet.snippet == String.slice(content, 0, 500) <> "…"
      assert snippet.snippet != content
    end

    test "a huge chunk yields a bounded snippet", %{source: source} do
      snippet = snippet_for(source, "huge", String.duplicate("z", 500_000))
      assert String.length(snippet.snippet) == 1001
    end

    test "only definition mentions produce snippets", %{source: source} do
      ingest(source, [
        {"c1", [def_("a")], [call("callee", "a")], []},
        {"c2", [], [call("a", nil)], []}
      ])

      callee = entity!(source, "callee")
      assert Graph.definition_snippets([callee.id]) == []
    end

    test ":limit defaults to 50, clamps to 50, and falls back on junk values", %{source: source} do
      specs = for n <- 1..60, do: {"k#{n}", [def_("merged")], [], [path: "f#{n}.py"]}
      ingest(source, specs)
      id = entity!(source, "merged").id

      assert length(Graph.definition_snippets([id])) == 50
      assert length(Graph.definition_snippets([id], limit: 999)) == 50
      assert length(Graph.definition_snippets([id], limit: 4)) == 4

      for junk <- [0, -1, nil, "3"] do
        assert length(Graph.definition_snippets([id], limit: junk)) == 50
      end

      assert Graph.definition_snippets([id], limit: 4) ==
               Graph.definition_snippets([id], limit: 4)
    end

    test "only the first 100 distinct ids are used", %{source: source} do
      ingest(source, [{"c1", [def_("a")], [], []}])
      id = entity!(source, "a").id
      filler = for _ <- 1..100, do: Ecto.UUID.generate()

      assert Graph.definition_snippets(filler ++ [id]) == []
      assert [_] = Graph.definition_snippets(List.duplicate(id, 150) ++ filler)
    end

    test "an empty entity_ids list short-circuits to an empty list" do
      assert Graph.definition_snippets([]) == []
    end
  end
end
