defmodule Mix.Tasks.Rn.Seed do
  @shortdoc "Seeds the thin corpus sources (git/jira/drive) and enqueues their first sync"

  @moduledoc """
  Registers the thin-corpus ingest sources (design-mcp.md Phase 9 Task 1) so the
  four MCP tools have data to answer over, then enqueues each source's first
  `*Sync` job the same way `Ingest.Workers.SyncScheduler`'s cron fan-out does.

  ## Git (always seedable, zero credentials)

  Registers this repository itself via a `file://` mirror of its own `.git` dir
  — no external service required. Override with:

      mix rn.seed --git-url file:///path/to/some/repo.git --repo some-repo

  ## Jira / Drive (only when credentials are present)

  Neither client reads credentials from the environment on its own (see
  `RetrievalNode.Ingest.Jira`/`Drive` moduledocs — they read
  `config :retrieval_node, :jira/:drive`, normally set at deploy time). This
  task is the one place that maps env vars to that config, so credentials can
  be supplied straight from the shell for a first seed:

    * Jira: `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_PROJECT_KEY`
      (all four required — the last becomes the JQL project and the source's
      `identifier`).
    * Drive: `DRIVE_ACCESS_TOKEN` (required), `DRIVE_FOLDER_ID` (optional label
      for the source's `identifier`/name; the Changes API syncs the whole
      Drive regardless, so this is a display slug, not a filter).

  Whichever process actually *runs* the enqueued sync job (the dev server or
  the production Oban instance) needs these same env vars at its own boot —
  setting them only for this task's shell configures the source, not that
  other process. When a var is missing, the source is left unregistered and a
  `SKIPPED` line names exactly what to set.

  ## Idempotency

  Rerunning is safe: each source is upserted on its `[:source_type, :identifier]`
  unique key (never duplicated), and every `*Sync` worker declares a `unique`
  window keyed on `source_id`, so a re-enqueue inside that window collapses onto
  the existing job instead of piling up.

  ## Status only

      mix rn.seed --status

  Prints registered sources with their chunk/pending-chunk counts and the
  `oban_jobs` state breakdown. Read-only — no sources are created or enqueued.
  """

  use Mix.Task

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.{DriveSync, JiraSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @default_repo_name "slow-henry"
  @default_git_url "file:///workspaces/slow-henry/.git"
  @default_drive_identifier "root"

  @switches [git_url: :string, repo: :string, status: :boolean]

  # run/1 ends in System.halt/1 (boot/0's ensure_all_started boots the full
  # supervision tree, which would otherwise keep the VM alive after seeding
  # finishes), so it genuinely never returns — the spec tells dialyzer that's
  # intentional.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} = OptionParser.parse(args, strict: @switches)

    boot()

    if opts[:status] do
      print_status()
    else
      seed(opts)
    end

    # boot/0 brings up the *entire* supervision tree (Endpoint, Oban, the
    # embedding Serving/Warmer sub-tree, ...) since Oban.insert/1 needs a
    # running Oban instance to resolve its config — none of which has a
    # reason to keep running once sources are seeded/status is printed.
    # Without an explicit halt, `mix rn.seed` would hang after printing (a
    # script/CI invocation would need to be killed rather than exiting on
    # its own).
    System.halt(0)
  end

  # --- boot ---

  # This task only needs Repo + Oban's insert path — `Oban.insert/1` requires a
  # running Oban instance to resolve its config, but NOT running queues. It
  # deliberately disables local queue/plugin execution and the ~1.2 GB embedding
  # model load: actual ingestion runs on the already-supervised Oban instance
  # (dev server / systemd), never inside this short-lived task process. If this
  # process's own queues raced to claim a job and then the task exited mid
  # `git clone --mirror`, it would leave a corrupt bare mirror behind.
  defp boot do
    Mix.Task.run("app.config")

    Application.put_env(:retrieval_node, :embedding_serving_start, false)

    oban_config = Application.get_env(:retrieval_node, Oban, [])

    Application.put_env(
      :retrieval_node,
      Oban,
      Keyword.merge(oban_config, queues: [], plugins: [])
    )

    {:ok, _} = Application.ensure_all_started(:retrieval_node)
  end

  # --- seed ---

  defp seed(opts) do
    seed_git(opts)
    seed_jira()
    seed_drive()

    Mix.shell().info("""

    Watch progress:
      PGPORT=5433 psql -h localhost -U postgres -d retrieval_node_dev -c \
    "select state, count(*) from oban_jobs group by state;"
      PGPORT=5433 psql -h localhost -U postgres -d retrieval_node_dev -c \
    "select count(*) from pending_chunks; select count(*) from chunks;"
    or: mix rn.seed --status
    """)
  end

  defp seed_git(opts) do
    name = opts[:repo] || @default_repo_name
    url = opts[:git_url] || @default_git_url

    {:ok, source} = upsert_source(%{source_type: :git_repo, name: name, identifier: url})

    enqueue!(RepoSync, source, "git repo #{inspect(name)} (#{url})")
  end

  @jira_vars ~w(JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN JIRA_PROJECT_KEY)

  defp seed_jira do
    case jira_env() do
      {:ok, %{base_url: base_url, email: email, api_token: api_token, project_key: project_key}} ->
        Application.put_env(:retrieval_node, :jira,
          base_url: base_url,
          email: email,
          api_token: api_token
        )

        {:ok, source} =
          upsert_source(%{
            source_type: :jira_project,
            name: "Jira: #{project_key}",
            identifier: project_key
          })

        enqueue!(JiraSync, source, "Jira project #{inspect(project_key)}")

      {:error, _missing} ->
        skip("Jira", @jira_vars)
    end
  end

  defp jira_env do
    case Enum.map(@jira_vars, &System.get_env/1) do
      [base_url, email, api_token, project_key]
      when is_binary(base_url) and is_binary(email) and is_binary(api_token) and
             is_binary(project_key) ->
        {:ok, %{base_url: base_url, email: email, api_token: api_token, project_key: project_key}}

      _ ->
        {:error, @jira_vars}
    end
  end

  @drive_vars ~w(DRIVE_ACCESS_TOKEN)

  defp seed_drive do
    case drive_env() do
      {:ok, %{access_token: access_token, folder_id: folder_id}} ->
        Application.put_env(:retrieval_node, :drive, access_token: access_token)

        {:ok, source} =
          upsert_source(%{
            source_type: :drive_folder,
            name: "Drive: #{folder_id}",
            identifier: folder_id
          })

        enqueue!(DriveSync, source, "Drive folder #{inspect(folder_id)}")

      {:error, _missing} ->
        skip("Drive", @drive_vars)
    end
  end

  defp drive_env do
    case System.get_env("DRIVE_ACCESS_TOKEN") do
      token when is_binary(token) ->
        folder_id = System.get_env("DRIVE_FOLDER_ID") || @default_drive_identifier
        {:ok, %{access_token: token, folder_id: folder_id}}

      _ ->
        {:error, @drive_vars}
    end
  end

  defp skip(label, vars) do
    Mix.shell().info(
      "SKIPPED #{label}: set #{Enum.join(vars, ", ")} (in the shell running this task AND " <>
        "wherever the sync job executes), then rerun `mix rn.seed`."
    )
  end

  # --- Source upsert (idempotent on the [:source_type, :identifier] unique key) ---

  @doc false
  @spec upsert_source(map()) :: {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def upsert_source(attrs) do
    %Source{}
    |> Source.create_changeset(attrs)
    |> Repo.insert(
      conflict_target: [:source_type, :identifier],
      on_conflict: {:replace, [:name, :updated_at]},
      returning: true
    )
  end

  defp enqueue!(worker, source, label) do
    case Oban.insert(worker.new(%{"source_id" => source.id})) do
      {:ok, %{conflict?: true}} ->
        Mix.shell().info(
          "~ #{label}: already registered, sync already queued/running (source_id=#{source.id})"
        )

      {:ok, _job} ->
        Mix.shell().info(
          "+ #{label}: registered, #{inspect(worker)} enqueued (source_id=#{source.id})"
        )

      {:error, reason} ->
        Mix.raise("failed to enqueue #{inspect(worker)} for #{label}: #{inspect(reason)}")
    end
  end

  # --- status (read-only) ---

  defp print_status do
    case Repo.all(from(s in Source, order_by: [asc: s.source_type, asc: s.name])) do
      [] -> Mix.shell().info("No sources registered yet. Run `mix rn.seed` first.")
      sources -> Enum.each(sources, &print_source_status/1)
    end

    print_job_status()
  end

  defp print_source_status(source) do
    chunk_count = Repo.aggregate(from(c in Chunk, where: c.source_id == ^source.id), :count, :id)

    pending_count =
      Repo.aggregate(from(p in PendingChunk, where: p.source_id == ^source.id), :count, :id)

    Mix.shell().info(
      "#{source.source_type} #{source.name} (#{source.identifier}) — " <>
        "active=#{source.active} chunks=#{chunk_count} pending=#{pending_count} " <>
        "last_synced=#{last_synced_at(source)}"
    )
  end

  defp last_synced_at(source) do
    case Repo.get_by(SyncState, source_id: source.id) do
      %{last_synced_at: %DateTime{} = ts} -> DateTime.to_iso8601(ts)
      _ -> "never"
    end
  end

  defp print_job_status do
    counts =
      Oban.Job
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.all()
      |> Map.new()

    Mix.shell().info("oban_jobs by state: #{inspect(counts)}")
  end
end
