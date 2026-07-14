defmodule RetrievalNode.Ingest.Workers.SyncScheduler do
  @moduledoc """
  Cron entrypoint. Source ids are dynamic (created at runtime), so cron can't carry
  them in static args — instead it fires this scheduler per source *kind*, which
  fans out one `*Sync` job per active, allow-policy source of that kind. The `*Sync`
  workers' `unique` constraint collapses any overlap with webhook triggers.
  """
  use Oban.Worker, queue: :sync, max_attempts: 3

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.{DriveSync, JiraSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source

  @kinds %{
    "git" => {:git_repo, RepoSync},
    "jira" => {:jira_project, JiraSync},
    "drive" => {:drive_folder, DriveSync}
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind}}) do
    {source_type, worker} = Map.fetch!(@kinds, kind)

    Source
    |> where([s], s.source_type == ^source_type and s.active == true and s.policy == :allow)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn source, :ok ->
      # A unique-constraint overlap comes back as {:ok, %{conflict?: true}} — fine.
      # A genuine {:error, _} would otherwise be swallowed and the cron tick would
      # look healthy despite the fan-out failing; surface it so Oban retries.
      case Oban.insert(worker.new(%{"source_id" => source.id})) do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
