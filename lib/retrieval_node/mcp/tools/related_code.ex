defmodule RetrievalNode.MCP.Tools.RelatedCode do
  @moduledoc """
  Code-knowledge-graph lookups for a function/class/module symbol — answers
  "who calls X", "what does X call", "where is X defined", and "who imports
  X". `entity` may be a bare name (`"process_payment"`) or a qualified one
  (`"PaymentProcessor.process_payment"`); resolution falls back from exact to
  suffix to fuzzy trigram match (see `RetrievalNode.Graph.find_entities/2`).

  `relation` picks the traversal (default `"definitions"`, which just returns
  where the matched entities are defined rather than traversing an edge):

    * `"definitions"` — where the matched entities are defined
    * `"callers"`     — entities that call the matched entities
    * `"callees"`     — entities the matched entities call
    * `"importers"`   — entities that import the matched entities, resolved
      via import mentions on definition chunks (most imports are file-level
      and never produce an edge — see `RetrievalNode.Graph.related_entities/3`)
    * `"imports"`     — entities the matched entities import, resolved the
      same way

  `hops: 2` extends `callers`/`callees`/`importers`/`imports` one edge
  further (transitive callers-of-callers, etc). Matching zero entities is a
  valid empty result, not an error, and so is a matched entity whose
  traversal finds nothing — either way the reply carries a `note` explaining
  why.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Graph

  @relation_map %{
    "definitions" => :definitions,
    "callers" => :callers,
    "callees" => :callees,
    "imports" => :imports,
    "importers" => :importers
  }

  # pg_trgm/word_similarity cost scales with input length; 256 bytes covers
  # any real qualified name (no legitimate module/class/function path gets
  # anywhere close).
  @max_entity_bytes 256

  schema do
    field(:entity, :string,
      required: true,
      description:
        "Function/class/module name, bare or qualified (e.g. \"process\" or \"PaymentProcessor.process\")"
    )

    field(:repo, :string, description: "Filter to entities seen in this repo (see list_repos)")
    field(:lang, :string, description: "Filter to entities in this language, e.g. python, elixir")

    field(:relation, :string,
      description:
        "One of definitions | callers | callees | imports | importers (default \"definitions\"). " <>
          "imports/importers are resolved via import mentions on definition chunks " <>
          "(most imports are file-level and carry no call-style edge); hop 2 follows the same relation."
    )

    field(:hops, :integer,
      description: "1 or 2 — traversal depth for non-definitions relations (default 1)"
    )
  end

  @impl true
  def execute(%{entity: entity} = params, frame) do
    with :ok <- validate_entity_length(entity),
         {:ok, relation} <- normalize_relation(Map.get(params, :relation)),
         {:ok, hops} <- normalize_hops(Map.get(params, :hops)) do
      run(entity, relation, hops, params, frame)
    else
      {:error, msg} -> {:reply, Response.error(Response.tool(), msg), frame}
    end
  end

  defp validate_entity_length(entity) when byte_size(entity) <= @max_entity_bytes, do: :ok

  defp validate_entity_length(entity) do
    {:error, "entity name too long (#{byte_size(entity)} bytes, max #{@max_entity_bytes})"}
  end

  defp run(entity, relation, hops, params, frame) do
    find_opts =
      [repo: Map.get(params, :repo), lang: Map.get(params, :lang)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Graph.find_entities(entity, find_opts) do
      [] ->
        note =
          "no entity matched #{inspect(entity)} — check spelling or try list_repos/grep first"

        {:reply, Response.json(Response.tool(), %{entities: [], note: note}), frame}

      matched ->
        payload = build_payload(matched, relation, hops)
        {:reply, Response.json(Response.tool(), payload), frame}
    end
  end

  defp build_payload(matched, :definitions, _hops) do
    %{
      entities: Enum.map(matched, &entity_result/1),
      definitions: matched |> Enum.map(& &1.id) |> Graph.definition_snippets()
    }
  end

  defp build_payload(matched, relation, hops) do
    related = matched |> Enum.map(& &1.id) |> Graph.related_entities(relation, hops)

    payload = %{
      entities: Enum.map(related, &related_result/1),
      definitions: related |> Enum.map(& &1.entity.id) |> Graph.definition_snippets()
    }

    case related do
      [] -> Map.put(payload, :note, empty_relation_note(relation))
      _ -> payload
    end
  end

  # The entity matched but the traversal found nothing — explain why per
  # relation family instead of returning a bare empty result, so an agent
  # consumer doesn't mistake "no edges yet" for "tool is broken".
  defp empty_relation_note(relation) when relation in [:importers, :imports] do
    "no import mentions or edges reference this entity — file-level " <>
      "`from X import Y`-style imports record both the module and the " <>
      "imported symbol only for content indexed after this change, so " <>
      "older chunks re-derive their import mentions on their next sync"
  end

  defp empty_relation_note(_relation) do
    "no call edges reference this entity"
  end

  defp entity_result(entity) do
    %{
      entity_id: entity.id,
      source_id: entity.source_id,
      qualified_name: entity.qualified_name,
      kind: entity.kind,
      language: entity.language
    }
  end

  defp related_result(%{entity: entity, weight: weight, hop: hop}) do
    %{
      entity_id: entity.id,
      source_id: entity.source_id,
      qualified_name: entity.qualified_name,
      kind: entity.kind,
      language: entity.language,
      weight: weight,
      hop: hop
    }
  end

  defp normalize_relation(nil), do: {:ok, :definitions}

  defp normalize_relation(relation) when is_map_key(@relation_map, relation),
    do: {:ok, @relation_map[relation]}

  defp normalize_relation(other) do
    valid = @relation_map |> Map.keys() |> Enum.sort() |> Enum.join(" | ")
    {:error, "unknown relation #{inspect(other)} — use #{valid}"}
  end

  defp normalize_hops(nil), do: {:ok, 1}
  defp normalize_hops(hops) when hops in [1, 2], do: {:ok, hops}
  defp normalize_hops(other), do: {:error, "invalid hops #{inspect(other)} — use 1 or 2"}
end
