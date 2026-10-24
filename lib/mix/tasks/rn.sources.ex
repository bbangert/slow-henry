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
    opts = parse_args!(args)
    path = opts[:file] || SourcesFile.default_path()

    entries =
      case SourcesFile.load(path) do
        {:ok, entries} -> entries
        {:error, msg} -> Mix.raise(msg)
      end

    # Same boot as rn.seed: Repo + Oban insert path only, no queues, no model.
    Seed.boot()

    result = if opts[:dry_run], do: SourcesFile.plan(entries), else: SourcesFile.apply(entries)

    changes =
      case result do
        {:ok, changes} -> changes
        {:error, msg} when is_binary(msg) -> Mix.raise("#{path}: #{msg}")
        {:error, reason} -> Mix.raise("could not apply #{path}: #{inspect(reason)}")
      end

    Mix.shell().info(
      "#{path}: #{length(entries)} source(s)#{if opts[:dry_run], do: " (dry run)"}"
    )

    Enum.each(changes, &Mix.shell().info(describe(&1)))

    System.halt(0)
  end

  @doc false
  @spec parse_args!([binary()]) :: keyword()
  def parse_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts

      {_, _, [_ | _] = invalid} ->
        Mix.raise("invalid option(s): #{Enum.map_join(invalid, " ", &format_invalid/1)}")

      {_, positional, []} ->
        Mix.raise("unexpected argument(s): #{Enum.join(positional, " ")}")
    end
  end

  defp format_invalid({switch, nil}), do: switch
  defp format_invalid({switch, value}), do: "#{switch}=#{value}"

  defp describe({:add, e}),
    do: "+ #{e.name} (#{e.identifier})#{if e.active, do: ", first sync", else: ", inactive"}"

  defp describe({:update, s, e}) do
    diffs =
      [
        s.name != e.name && rename(s, e),
        s.active != e.active && "active #{s.active} -> #{e.active}",
        (e.active and not s.active) && sync_note(s)
      ]
      |> Enum.filter(& &1)

    "~ #{e.name}: #{Enum.join(diffs, ", ")}"
  end

  defp describe({:deactivate, s}), do: "- #{s.name}: not in file, deactivated (chunks kept)"
  defp describe({:unchanged, s}), do: "= #{s.name}"

  defp sync_note(%{policy: :allow}), do: "sync"
  defp sync_note(%{policy: policy}), do: "not synced (policy #{policy})"

  defp rename(s, e) do
    case SourcesFile.pinned_slug(s, e) do
      nil -> "name #{s.name} -> #{e.name}"
      slug -> "name #{s.name} -> #{e.name} (slug #{inspect(slug)} kept)"
    end
  end
end
