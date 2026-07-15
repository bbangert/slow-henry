defmodule RetrievalNode.ReleaseTest do
  use ExUnit.Case, async: true

  # migrate/0 and rollback/2 open their own DB connection via
  # Ecto.Migrator.with_repo, outside the Ecto.Adapters.SQL.Sandbox checkout
  # this suite otherwise requires (see test/test_helper.exs's :manual mode) —
  # exercising them for real here would mean either fighting the sandbox or
  # migrating the shared test database out of band. The test suite already
  # exercises the underlying `Ecto.Migrator.run/3` machinery via
  # `mix ecto.migrate` in CI/dev setup, so this just guards the release
  # entrypoint itself: the module loads under a release-style boot (no Mix)
  # and exposes the arity `bin/retrieval_node eval` calls.
  test "exposes migrate/0 and rollback/2" do
    assert Code.ensure_loaded?(RetrievalNode.Release)
    assert function_exported?(RetrievalNode.Release, :migrate, 0)
    assert function_exported?(RetrievalNode.Release, :rollback, 2)
  end

  test "reads ecto_repos from application env, matching config.exs" do
    assert Application.fetch_env!(:retrieval_node, :ecto_repos) == [RetrievalNode.Repo]
  end
end
