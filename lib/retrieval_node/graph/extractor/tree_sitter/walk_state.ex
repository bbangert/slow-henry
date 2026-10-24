defmodule RetrievalNode.Graph.Extractor.TreeSitter.WalkState do
  @moduledoc """
  The context `RetrievalNode.Graph.Extractor.TreeSitter` threads down its
  full-tree walk. It is immutable: a definition builds a fresh state for its
  subtree and siblings never see each other's changes.

  Entering a definition goes through `handle_definition_category/8`, which
  builds the child state from scratch: `scope`, `mod_scope`, `container_kind`,
  `enclosing_qname`, `receiver` and `pending_receiver` are recomputed, while the
  one-shot fields (`self_target`, `keys_done`) are reset to their defaults.
  Non-definition nodes (arrow functions, Ruby singleton classes, Java anonymous
  class bodies, ...) pass the state down with only the listed fields updated.

  ## Fields

    * `scope` - segments of the enclosing NAMED definitions; joined with "."
      (plus the definition's own name) to form a `qualified_name`. Starts `[]`.
      Extended when a named definition is entered. Also overridden by Rust impl
      path resolution (`crate::`, `super::`), a Ruby rooted `class ::A`, a Ruby
      `class << A` body and a Ruby `def` nested in a method (which restarts at
      the containing class).
    * `mod_scope` - Rust module path only (`mod` items), never function or impl
      names; the base that `self::`/`super::` impl type paths resolve against.
      Extended only by a named Rust `module_like` definition.
    * `container_kind` - category (`:function_like`, `:class_like`,
      `:module_like`, `:method_like`) of the nearest enclosing definition, or
      `nil` at top level. Decides `:function` vs `:method` for the next
      function-like node. Set to the entered definition's category, also for
      anonymous ones (so a method inside an arrow function is still classified
      against that function). Arrow functions set `:function_like`; Java
      anonymous class bodies set `:class_like`.
    * `enclosing_qname` - `qualified_name` of the nearest NAMED enclosing
      definition, or `nil`; used as `from` on references. An anonymous
      definition leaves it unchanged. Always names an entity of the same file.
    * `receiver` - qualified name that `self`/`this` calls resolve to, or `nil`
      when unresolved (callees then stay bare). Set when a class-like or
      module-like definition (or a Ruby method with a statically named
      receiver) is entered, and inherited by nested definitions. Cleared at
      receiver boundaries: JS/TS functions that rebind `this`, object-literal
      methods, unnamed classes, Python functions taking their own `self` when
      nested in a function, Python lambdas taking `self`, Java anonymous class
      bodies, and Ruby singleton methods/classes on unresolvable objects.
    * `pending_receiver` - ONE-SHOT, Python only. The class a just-entered
      `class_definition` would bind, held back because a class body keeps the
      OUTER `receiver`. Set when entering a Python class; consumed by a
      function defined directly in that class body that takes `self`. Reset to
      `nil` by every other definition.
    * `self_target` - ONE-SHOT. Names the qualified-name suffix that
      `receiver` should take instead of the entity's own name: the impl TYPE
      for a Rust `impl Trait for T` (entities are scoped `T.Trait`, `self`
      targets `T`) and the receiver constant for a Ruby `def A.x`. Set by those
      definition clauses just before `handle_definition_category/8`, consumed
      there and reset to `nil` in the child state.
    * `keys_done` - ONE-SHOT, JS/TS only. `true` on the state passed to a class
      member definition whose computed key was already walked in the class's
      enclosing state, so `walk_definition/8` skips it. Set by the class-body
      walker; reset to `false` in the child state.
  """

  @type category :: :function_like | :class_like | :module_like | :method_like

  @type t :: %__MODULE__{
          scope: [String.t()],
          mod_scope: [String.t()],
          container_kind: category() | nil,
          enclosing_qname: String.t() | nil,
          receiver: String.t() | nil,
          pending_receiver: String.t() | nil,
          self_target: String.t() | nil,
          keys_done: boolean()
        }

  defstruct scope: [],
            mod_scope: [],
            container_kind: nil,
            enclosing_qname: nil,
            receiver: nil,
            pending_receiver: nil,
            self_target: nil,
            keys_done: false
end
