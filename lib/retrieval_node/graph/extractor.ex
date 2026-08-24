defmodule RetrievalNode.Graph.Extractor do
  @moduledoc """
  Behaviour for extracting code-knowledge-graph rows (entity definitions and
  references) from a source file. Mirrors Arcana's `GraphExtractor` shape: a
  single `extract/3` callback parameterized on an impl-defined `input`, so a
  tree-sitter impl (an already-parsed AST) and a future LLM impl (raw text)
  can share one seam.

  Output shapes map directly onto the eventual persistence targets
  (`RetrievalNode.Graph.Entity` / `EntityMention` / `EntityEdge`, Phase 8+):
  an `entity` becomes a definition-kind `entity_mention` plus its owning
  `Entity` row; a `reference` becomes a call/import-kind `entity_mention`,
  and when its `from` is non-nil, a candidate `entity_edge` from the
  enclosing definition to the referenced name.
  """

  @typedoc "A definition site: a named function/method/class/module."
  @type entity :: %{
          qualified_name: String.t(),
          kind: :function | :method | :class | :module,
          line: pos_integer()
        }

  @typedoc """
  A call or import reference. `from` is the qualified_name of the enclosing
  definition (nil when the reference sits at top level, outside any named
  definition) — this is what lets persistence build def -> callee edges.

  Named `ref` rather than `reference` because `reference/0` is a built-in
  Elixir typespec (the `make_ref/0` reference type) and cannot be redefined.
  """
  @type ref :: %{
          name: String.t(),
          kind: :call | :import,
          from: String.t() | nil,
          line: pos_integer()
        }

  @doc """
  Extract entities and references from `input` (impl-defined — e.g. the
  tree-sitter impl takes `{root_node, source}`, an already-parsed tree; a
  future LLM impl would take raw text).
  """
  @callback extract(input :: term(), language :: String.t(), opts :: keyword()) ::
              {:ok, %{entities: [entity], references: [ref]}} | {:error, term()}
end
