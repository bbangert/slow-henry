defmodule RetrievalNode.Release do
  @moduledoc """
  Release tasks for running Ecto migrations without Mix.

  Mix isn't available in a `mix release` build, so this is the entrypoint
  ops invokes from the release script instead of `mix ecto.migrate`:

      bin/retrieval_node eval "RetrievalNode.Release.migrate()"

  See `scripts/deploy.sh` (runs this between the symlink switch and
  `systemctl restart`) and `deploy/README.md`.
  """

  @app :retrieval_node

  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
