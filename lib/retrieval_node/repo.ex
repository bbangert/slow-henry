defmodule RetrievalNode.Repo do
  use Ecto.Repo,
    otp_app: :retrieval_node,
    adapter: Ecto.Adapters.Postgres
end
