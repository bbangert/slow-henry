defmodule RetrievalNode.SourcesFile do
  @moduledoc """
  `sources.toml` is the source of truth for the git repos that are indexed.
  It is git-ignored (it names private repos); `sources.example.toml` is the
  template.

      [[git]]
      name = "adr"                                  # mirror slug + MCP `repo` filter
      url = "https://github.com/my-org/adr.git"     # clone URL (the source identity)
      # active = false                              # keep indexed chunks, stop syncing

  `apply/1` aligns the `sources` table with the file:

    * an entry with no matching source is **added** and gets its first sync;
    * a known one whose name or `active` flag differs is **updated**;
      re-activation triggers a sync;
    * a git source in the database but no longer in the file is
      **deactivated** — never deleted, so its chunks stay searchable and
      putting it back resumes from its cursor.

  Jira and Drive are still registered by `mix rn.seed` from their credentials.
  """

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source

  @default_path "sources.toml"
  @managed_types [:git_repo]
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @url_schemes ~w(https:// http:// ssh:// git:// file://)

  @typedoc "A source as the file wants it."
  @type entry :: %{
          source_type: :git_repo,
          identifier: String.t(),
          name: String.t(),
          active: boolean(),
          config: map()
        }
  @type change ::
          {:add, entry()}
          | {:update, Source.t(), entry()}
          | {:deactivate, Source.t()}
          | {:unchanged, Source.t()}

  @doc "The file to read: `SOURCES_FILE` if set, else `sources.toml`."
  def default_path, do: System.get_env("SOURCES_FILE") || @default_path

  @doc "Reads and validates the file."
  @spec load(Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def load(path) do
    with {:ok, body} <- read(path),
         {:ok, doc} <- decode(path, body) do
      parse(doc)
    end
  end

  @doc "Validates an already-decoded TOML document."
  @spec parse(map()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(doc) do
    with :ok <- known_sections(doc),
         {:ok, raw} <- git_tables(doc),
         {:ok, git} <- collect(raw),
         :ok <- unique(git, :name),
         :ok <- unique(git, :identifier) do
      {:ok, git}
    end
  end

  @doc "What `apply/1` would do, without writing anything."
  @spec plan([entry()]) :: [change()]
  def plan(entries) do
    existing = Repo.all(from s in Source, where: s.source_type in ^@managed_types)
    by_key = Map.new(existing, &{{&1.source_type, &1.identifier}, &1})
    wanted = MapSet.new(entries, &{&1.source_type, &1.identifier})

    planned = Enum.map(entries, &plan_entry(&1, by_key))

    retired =
      for s <- existing,
          s.active,
          not MapSet.member?(wanted, {s.source_type, s.identifier}),
          do: {:deactivate, s}

    planned ++ retired
  end

  defp plan_entry(entry, by_key) do
    case Map.fetch(by_key, {entry.source_type, entry.identifier}) do
      :error -> {:add, entry}
      {:ok, s} -> if same?(s, entry), do: {:unchanged, s}, else: {:update, s, entry}
    end
  end

  defp same?(s, e),
    do: s.name == e.name and s.active == e.active and (s.config || %{}) == e.config

  @doc """
  Applies `plan/1` in one transaction, then enqueues a sync for every added or
  re-activated source.
  Requires a running Oban instance.
  """
  @spec apply([entry()]) :: {:ok, [change()]} | {:error, term()}
  def apply(entries) do
    changes = plan(entries)

    result = Repo.transaction(fn -> Enum.map(changes, &write!/1) end)

    with {:ok, written} <- result do
      for {change, source} <- written, needs_sync?(change), do: enqueue!(source)
      {:ok, changes}
    end
  end

  defp write!(change) do
    case write(change) do
      {:ok, source} -> {change, source}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write({:add, e}) do
    %Source{}
    |> Source.create_changeset(Map.take(e, [:source_type, :identifier, :name, :active, :config]))
    |> Repo.insert()
  end

  defp write({:update, s, e}),
    do: s |> Source.update_changeset(Map.take(e, [:name, :active, :config])) |> Repo.update()

  defp write({:deactivate, s}),
    do: s |> Source.update_changeset(%{active: false}) |> Repo.update()

  defp write({:unchanged, s}), do: {:ok, s}

  defp needs_sync?({:add, e}), do: e.active
  defp needs_sync?({:update, s, e}), do: e.active and not s.active
  defp needs_sync?(_), do: false

  defp enqueue!(source) do
    {:ok, _job} = Oban.insert(RepoSync.new(%{"source_id" => source.id}))
  end

  # --- reading / validation ---

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        {:error, "cannot read #{path}: no such file (start from sources.example.toml)"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(path, body) do
    case Toml.decode(body) do
      {:ok, doc} -> {:ok, doc}
      {:error, {:invalid_toml, reason}} -> {:error, "#{path}: #{reason}"}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  defp known_sections(doc) do
    case Map.keys(doc) -- ~w(git) do
      [] -> :ok
      unknown -> {:error, "unknown section(s) #{Enum.join(unknown, ", ")}"}
    end
  end

  defp git_tables(doc) do
    case Map.get(doc, "git", []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "`git` must be an array of tables ([[git]])"}
    end
  end

  defp collect(raw) do
    raw
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
      case git_entry(item) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        {:error, msg} -> {:halt, {:error, "[[git]] ##{i}: #{msg}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp git_entry(%{"name" => name, "url" => url} = item)
       when is_binary(name) and is_binary(url) do
    active = Map.get(item, "active", true)
    unknown = Map.keys(item) -- ~w(name url active)

    cond do
      unknown != [] ->
        {:error, "unknown key(s) #{Enum.join(unknown, ", ")}"}

      not Regex.match?(@name_format, name) ->
        {:error, "invalid name #{inspect(name)}"}

      not Enum.any?(@url_schemes, &String.starts_with?(url, &1)) ->
        {:error, "invalid url #{inspect(url)}"}

      not is_boolean(active) ->
        {:error, "`active` must be true or false"}

      true ->
        {:ok, %{source_type: :git_repo, identifier: url, name: name, active: active, config: %{}}}
    end
  end

  defp git_entry(_), do: {:error, "`name` and `url` are required strings"}

  defp unique(entries, key) do
    case entries
         |> Enum.frequencies_by(&Map.fetch!(&1, key))
         |> Enum.find(fn {_, n} -> n > 1 end) do
      nil ->
        :ok

      {value, _} ->
        {:error, "duplicate #{if key == :identifier, do: "url", else: key} #{inspect(value)}"}
    end
  end
end
