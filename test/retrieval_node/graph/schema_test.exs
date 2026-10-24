defmodule RetrievalNode.Graph.SchemaTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Graph.{Entity, EntityEdge, EntityMention}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  defp source_fixture(identifier \\ "repo-#{System.unique_integer([:positive])}") do
    Repo.insert!(%Source{
      source_type: :git_repo,
      name: identifier,
      identifier: identifier
    })
  end

  defp chunk_fixture(source, attrs \\ %{}) do
    defaults = %{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "hash-#{System.unique_integer([:positive])}",
      content: "def process(x), do: x",
      context_breadcrumb: "lib/payment.ex > PaymentProcessor > process/1",
      metadata: %{}
    }

    Repo.insert!(struct(Chunk, Map.merge(defaults, Map.new(attrs))))
  end

  defp entity_fixture(source, attrs \\ %{}) do
    defaults = %{
      source_id: source.id,
      language: "elixir",
      qualified_name: "PaymentProcessor.process",
      kind: :function
    }

    Repo.insert!(struct(Entity, Map.merge(defaults, Map.new(attrs))))
  end

  describe "insert round-trip" do
    test "entity -> mention -> edge insert via Repo" do
      source = source_fixture()
      chunk = chunk_fixture(source)

      entity = entity_fixture(source)
      callee = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      mention =
        Repo.insert!(%EntityMention{
          entity_id: entity.id,
          chunk_id: chunk.id,
          kind: :definition
        })

      edge =
        Repo.insert!(%EntityEdge{
          source_entity_id: entity.id,
          target_entity_id: callee.id,
          kind: :calls,
          weight: 3
        })

      assert Repo.get!(EntityMention, mention.id).kind == :definition
      assert Repo.get!(EntityEdge, edge.id).weight == 3
    end
  end

  describe "unique constraints" do
    test "duplicate (source_id, language, qualified_name) on entities raises" do
      source = source_fixture()
      entity_fixture(source)

      assert_raise Ecto.ConstraintError, fn ->
        entity_fixture(source)
      end
    end

    test "duplicate (entity_id, chunk_id, kind) on entity_mentions raises" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      entity = entity_fixture(source)

      Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: :definition})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: :definition})
      end
    end

    test "duplicate (source_entity_id, target_entity_id, kind, chunk_id) via EntityEdge.changeset/2 surfaces as a changeset error, not Ecto.ConstraintError" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      a = entity_fixture(source)
      b = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      attrs = %{source_entity_id: a.id, target_entity_id: b.id, kind: :calls, chunk_id: chunk.id}

      assert {:ok, _edge} = %EntityEdge{} |> EntityEdge.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} = %EntityEdge{} |> EntityEdge.changeset(attrs) |> Repo.insert()
      refute changeset.valid?
      assert %{source_entity_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "duplicate (source_entity_id, target_entity_id, kind, chunk_id) via a raw Repo.insert! (bypassing the changeset) still raises Ecto.ConstraintError" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      a = entity_fixture(source)
      b = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      Repo.insert!(%EntityEdge{
        source_entity_id: a.id,
        target_entity_id: b.id,
        kind: :calls,
        chunk_id: chunk.id
      })

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%EntityEdge{
          source_entity_id: a.id,
          target_entity_id: b.id,
          kind: :calls,
          chunk_id: chunk.id
        })
      end
    end

    test "the same (source_entity_id, target_entity_id, kind) triple contributed by two DIFFERENT chunks does not raise" do
      # This is the whole point of chunk-level provenance: two files (two
      # chunks) contributing an outgoing edge for the same merged entity must
      # be able to coexist as distinct rows instead of colliding.
      source = source_fixture()
      chunk_a = chunk_fixture(source)
      chunk_b = chunk_fixture(source)
      a = entity_fixture(source)
      b = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      Repo.insert!(%EntityEdge{
        source_entity_id: a.id,
        target_entity_id: b.id,
        kind: :calls,
        chunk_id: chunk_a.id
      })

      Repo.insert!(%EntityEdge{
        source_entity_id: a.id,
        target_entity_id: b.id,
        kind: :calls,
        chunk_id: chunk_b.id
      })

      assert Repo.aggregate(EntityEdge, :count, :id) == 2
    end

    test "legacy NULL chunk_id rows for the same triple do not collide (Postgres treats NULL as distinct in a unique index)" do
      source = source_fixture()
      a = entity_fixture(source)
      b = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      Repo.insert!(%EntityEdge{source_entity_id: a.id, target_entity_id: b.id, kind: :calls})
      Repo.insert!(%EntityEdge{source_entity_id: a.id, target_entity_id: b.id, kind: :calls})

      assert Repo.aggregate(EntityEdge, :count, :id) == 2
    end
  end

  describe "cascade deletes" do
    test "deleting a chunk cascades its mentions" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      entity = entity_fixture(source)

      mention =
        Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: :definition})

      Repo.delete!(chunk)

      refute Repo.get(EntityMention, mention.id)
    end

    test "deleting an entity cascades its mentions and edges" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      entity = entity_fixture(source)
      other = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      mention =
        Repo.insert!(%EntityMention{entity_id: entity.id, chunk_id: chunk.id, kind: :definition})

      edge =
        Repo.insert!(%EntityEdge{
          source_entity_id: entity.id,
          target_entity_id: other.id,
          kind: :calls
        })

      Repo.delete!(entity)

      refute Repo.get(EntityMention, mention.id)
      refute Repo.get(EntityEdge, edge.id)
    end

    test "deleting a chunk cascades its provenance edge (chunk_id FK), same lifecycle as mentions" do
      source = source_fixture()
      chunk = chunk_fixture(source)
      a = entity_fixture(source)
      b = entity_fixture(source, %{qualified_name: "PaymentProcessor.charge"})

      edge =
        Repo.insert!(%EntityEdge{
          source_entity_id: a.id,
          target_entity_id: b.id,
          kind: :calls,
          chunk_id: chunk.id
        })

      Repo.delete!(chunk)

      refute Repo.get(EntityEdge, edge.id)
      # the entities themselves have no FK back to chunks — they survive.
      assert Repo.get(Entity, a.id)
      assert Repo.get(Entity, b.id)
    end
  end
end
