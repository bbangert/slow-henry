# Excluded by default:
#   * :integration — loads the embedding/reranking models + EXLA (slow, large
#     downloads). Run with `mix test --include integration`.
#   * :tree_sitter — real tree-sitter parsing: loads the NIF and needs the
#     grammars in its on-disk cache (`mix rn.grammars.prefetch`). CI prefetches
#     and runs these; locally run `mix test --include tree_sitter`.
ExUnit.start(exclude: [:integration, :tree_sitter])
Ecto.Adapters.SQL.Sandbox.mode(RetrievalNode.Repo, :manual)
