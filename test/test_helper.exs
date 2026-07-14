# Exclude tests tagged :integration by default (they load the embedding model +
# EXLA, which is slow and network-dependent). Run them with:
#   mix test --include integration
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(RetrievalNode.Repo, :manual)
