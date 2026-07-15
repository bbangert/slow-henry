defmodule Mix.Tasks.Rn.Grammars.Prefetch do
  @shortdoc "Prefetches tree-sitter grammars required by RetrievalNode.Chunking.Grammars"

  @moduledoc """
  Downloads every grammar `RetrievalNode.Chunking.Grammars.required/0` lists
  into the `tree_sitter_language_pack` NIF's on-disk cache, so a fresh deploy
  (or a fresh build image) doesn't pay a cold-cache download on the first
  real parse.

  ## Cache location

  The NIF resolves its cache directory from the `XDG_CACHE_HOME` environment
  variable of the *calling* OS process (falling back to the platform default
  cache dir when unset) — not from anything Mix- or Elixir-configured. Set
  `XDG_CACHE_HOME` before invoking this task (e.g. in the Dockerfile build
  step or CI job) if the grammars need to land in a specific, cacheable
  location:

      XDG_CACHE_HOME=/app/.cache mix rn.grammars.prefetch

  ## Bootstrap

  Only `app.config` is run — the NIF is a plain Rustler load triggered by
  compiling/loading its module, not something the `:retrieval_node` OTP
  application (Repo, Endpoint, Oban, ...) needs to be started for. Running
  the full `app.start` here would need a live Postgres connection just to
  prefetch grammar files, which is unnecessary and slower in CI/build
  contexts where no database is available yet.

  Exits nonzero (via `Mix.raise/1`) if any required grammar is still missing
  after the download attempt, so a CI/build pipeline fails loudly instead of
  shipping an image with a cold cache.
  """

  use Mix.Task

  alias RetrievalNode.Chunking.Grammars

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    {:ok, cache_dir} = TreeSitterLanguagePack.cache_dir()
    Mix.shell().info("Grammar cache dir: #{cache_dir}")

    Grammars.prefetch()

    report(Grammars.missing())
  end

  defp report([]), do: Mix.shell().info("Grammar cache: all required languages present.")

  defp report(missing) do
    Mix.raise("Grammar cache incomplete after prefetch — still missing: #{inspect(missing)}")
  end
end
