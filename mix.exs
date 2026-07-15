defmodule RetrievalNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :retrieval_node,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Self-hosted arm64 release (see scripts/build_arm64.sh, deploy/README.md).
  # v1 has no Erlang distribution / peer nodes, so no :cookie is configured
  # here — rel/env.sh.eex sets RELEASE_DISTRIBUTION=none instead.
  defp releases do
    [
      retrieval_node: [
        include_executables_for: [:unix],
        # rel/overlays (always included by default) carries rel/overlays/grammar-cache,
        # the prefetched tree-sitter grammar cache staged by scripts/build_arm64.sh
        # before this step runs, so it ships inside the tarball.
        overlays: ["rel/overlays"],
        # Emit _build/prod/retrieval_node-<vsn>.tar.gz for scripts/deploy.sh to unpack.
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Keep the PLT in priv/plts so CI can cache it as a stable path.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {RetrievalNode.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Retrieval Node stack
      {:anubis_mcp, "~> 1.6"},
      {:oban, "~> 2.18"},
      {:pgvector, "~> 0.3"},
      {:bumblebee, "~> 0.7"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      {:tree_sitter_language_pack, "~> 1.12"},
      {:req, "~> 0.5"},
      # Explicit dep: we start Finch ourselves in the supervision tree (shared
      # Jira/Drive HTTP pool) rather than relying on it being started implicitly
      # as a transitive dep of req/anubis_mcp.
      {:finch, "~> 0.23"},
      {:sourceror, "~> 1.0"},

      # Tooling used by per-phase verification (mix credo/sobelow) and CI (dialyzer)
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
