defmodule Mix.Tasks.Rn.BenchTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Rn.Bench

  describe "admin_oban_config/1" do
    test "strips queues, plugins and peer while keeping the rest of the config" do
      config = [
        repo: RetrievalNode.Repo,
        queues: [sync: 3],
        plugins: [{Oban.Plugins.Pruner, max_age: 1}]
      ]

      result = Bench.admin_oban_config(config)

      assert result[:queues] == []
      assert result[:plugins] == []
      assert result[:peer] == false
      assert result[:repo] == RetrievalNode.Repo
    end
  end
end
