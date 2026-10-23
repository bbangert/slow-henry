defmodule Mix.Tasks.Rn.Sources do
  @shortdoc "Aligns the registered git sources with sources.toml"

  @moduledoc """
  Reads `sources.toml` (or `SOURCES_FILE`, or `--file PATH`) and aligns the
  `sources` table with it — see `RetrievalNode.SourcesFile` for the format and
  the rules. Added and re-activated repos get their first sync enqueued; the
  running server's Oban picks it up.

      mix rn.sources            # apply
      mix rn.sources --dry-run  # print the plan, write nothing
  """

  use Mix.Task

  alias Mix.Tasks.Rn.Seed
  alias RetrievalNode.SourcesFile

  @switches [file: :string, dry_run: :boolean]

  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} = OptionParser.parse(args, strict: @switches)
    path = opts[:file] || SourcesFile.default_path()

    entries =
      case SourcesFile.load(path) do
        {:ok, entries} -> entries
        {:error, msg} -> Mix.raise(msg)
      end

    # Same boot as rn.seed: Repo + Oban insert path only, no queues, no model.
    Seed.boot()

    changes =
      if opts[:dry_run] do
        SourcesFile.plan(entries)
      else
        case SourcesFile.apply(entries) do
          {:ok, changes} -> changes
          {:error, reason} -> Mix.raise("could not apply #{path}: #{inspect(reason)}")
        end
      end

    Mix.shell().info(
      "#{path}: #{length(entries)} source(s)#{if opts[:dry_run], do: " (dry run)"}"
    )

    Enum.each(changes, &Mix.shell().info(describe(&1)))

    System.halt(0)
  end

  defp describe({:add, e}),
    do: "+ #{e.name} (#{e.identifier})#{if e.active, do: ", first sync", else: ", inactive"}"

  defp describe({:update, s, e}) do
    diffs =
      [
        s.name != e.name && "name #{s.name} -> #{e.name}",
        s.active != e.active && "active #{s.active} -> #{e.active}",
        (e.active and not s.active) && "sync"
      ]
      |> Enum.filter(& &1)

    "~ #{e.name}: #{Enum.join(diffs, ", ")}"
  end

  defp describe({:deactivate, s}), do: "- #{s.name}: not in file, deactivated (chunks kept)"
  defp describe({:unchanged, s}), do: "= #{s.name}"
end
