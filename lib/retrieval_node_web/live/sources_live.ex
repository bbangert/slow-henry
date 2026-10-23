defmodule RetrievalNodeWeb.SourcesLive do
  @moduledoc "Overview of every indexed source and of the Oban sync jobs."
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.Inventory
  alias RetrievalNodeWeb.Format

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok, socket |> assign(:page_title, "Sources") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("sync", %{"id" => id}, socket) do
    socket =
      case Inventory.get_source(id) do
        %{source: source} -> enqueue(socket, source)
        nil -> put_flash(socket, :error, "Could not queue a sync for this source.")
      end

    {:noreply, load(socket)}
  end

  defp enqueue(socket, source) do
    case Inventory.enqueue_sync(source) do
      {:ok, job} ->
        msg =
          if job.conflict?,
            do: "A sync for #{source.name} is already queued.",
            else: "Sync queued for #{source.name}."

        put_flash(socket, :info, msg)

      {:error, :ineligible} ->
        put_flash(
          socket,
          :error,
          "#{source.name} is inactive or denied by policy; it is not synced."
        )

      _ ->
        put_flash(socket, :error, "Could not queue a sync for this source.")
    end
  end

  defp load(socket) do
    rows = Inventory.list_sources()
    jobs = Inventory.job_summary()
    names = Map.new(rows, &{&1.source.id, &1.source.name})

    assign(socket,
      rows: rows,
      jobs: jobs,
      source_names: names,
      totals: %{
        sources: length(rows),
        chunks: Enum.sum_by(rows, & &1.chunks),
        files: Enum.sum_by(rows, & &1.files),
        pending: Enum.sum_by(rows, & &1.pending),
        # Indexing (chunk + embed) runs in each source's SourceOwner, outside
        # Oban: a source is indexing while it has staged files left.
        indexing: Enum.count(rows, &(&1.pending > 0))
      }
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:sources}>
      <div class="stats stats-vertical sm:stats-horizontal w-full border border-base-300">
        <.stat title="Sources" value={@totals.sources} />
        <.stat title="Files" value={@totals.files} />
        <.stat title="Chunks" value={@totals.chunks} />
        <.stat title="Pending" value={@totals.pending} />
        <.stat title="Sources indexing" value={@totals.indexing} />
      </div>

      <section>
        <h2 class="mb-2 text-lg font-semibold">Sources</h2>
        <div class="overflow-x-auto rounded-box border border-base-300">
          <table id="sources" class="table table-sm">
            <thead>
              <tr>
                <th>Source</th>
                <th class="text-right">Files</th>
                <th class="text-right">Chunks</th>
                <th class="text-right">Pending</th>
                <th>Last sync</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"source-#{row.source.id}"} class="hover:bg-base-200">
                <td>
                  <.link navigate={~p"/sources/#{row.source.id}"} class="link link-hover font-medium">
                    {row.source.name}
                  </.link>
                  <span class="badge badge-ghost badge-sm ml-1">
                    {Format.source_type(row.source.source_type)}
                  </span>
                  <span :if={!row.source.active} class="badge badge-warning badge-sm ml-1">
                    inactive
                  </span>
                  <div class="text-xs opacity-60">{row.source.identifier}</div>
                </td>
                <td class="text-right tabular-nums">{row.files}</td>
                <td class="text-right tabular-nums">
                  {row.chunks}
                  <span :if={row.redacted > 0} class="badge badge-warning badge-xs" title="redacted">
                    {row.redacted} redacted
                  </span>
                </td>
                <td class="text-right tabular-nums">
                  {row.pending}
                  <span :if={row.failing > 0} class="badge badge-error badge-xs">
                    {row.failing} failing
                  </span>
                </td>
                <td class="whitespace-nowrap">{Format.ago(row.sync && row.sync.last_synced_at)}</td>
                <td>
                  <.sync_status sync={row.sync} pending={row.pending} />
                </td>
                <td class="text-right">
                  <button
                    id={"sync-#{row.source.id}"}
                    phx-click="sync"
                    phx-value-id={row.source.id}
                    class="btn btn-ghost btn-xs"
                    disabled={!(row.source.active and row.source.policy == :allow)}
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Sync
                  </button>
                </td>
              </tr>
              <tr :if={@rows == []}>
                <td colspan="7" class="py-6 text-center opacity-60">
                  No source registered yet. Add one with <code>mix rn.seed</code>.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 class="mb-2 text-lg font-semibold">Jobs</h2>
        <div class="mb-3 flex flex-wrap gap-2">
          <span :for={{state, count} <- Enum.sort(@jobs.counts)} class="badge badge-outline">
            {state}: {count}
          </span>
          <span :if={@jobs.counts == %{}} class="opacity-60">No jobs yet.</span>
        </div>

        <div :if={@jobs.errored != []} class="overflow-x-auto rounded-box border border-base-300">
          <table id="errored-jobs" class="table table-sm">
            <thead>
              <tr>
                <th>Worker</th>
                <th>Source</th>
                <th>State</th>
                <th>Attempt</th>
                <th>When</th>
                <th>Last error</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @jobs.errored} id={"job-#{job.id}"}>
                <td>{Format.worker(job.worker)}</td>
                <td>{Map.get(@source_names, job.args["source_id"], "—")}</td>
                <td><span class="badge badge-sm">{job.state}</span></td>
                <td class="tabular-nums">{job.attempt}/{job.max_attempts}</td>
                <td class="whitespace-nowrap">{Format.ago(job.attempted_at)}</td>
                <td class="max-w-md">
                  <pre class="whitespace-pre-wrap break-words text-xs">{last_error(job)}</pre>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="stat">
      <div class="stat-title">{@title}</div>
      <div class="stat-value text-2xl tabular-nums">{@value}</div>
    </div>
    """
  end

  attr :sync, :any, required: true
  attr :pending, :integer, required: true

  defp sync_status(assigns) do
    assigns = assign(assigns, :label, status_label(assigns.sync, assigns.pending))

    ~H"""
    <span class={["badge badge-sm", status_class(@label)]}>{@label}</span>
    <div :if={@sync && @sync.last_error} class="text-xs text-error" title={@sync.last_error}>
      {Format.truncate(@sync.last_error, 80)}
    </div>
    """
  end

  # Staged files mean the SourceOwner is (or will be) indexing, whatever the
  # discovery job's own state says.
  defp status_label(sync, pending) when pending > 0 and (is_nil(sync) or sync.status == :idle),
    do: :indexing

  defp status_label(nil, _pending), do: :"not synced"
  defp status_label(sync, _pending), do: sync.status

  defp status_class(:idle), do: "badge-success"
  defp status_class(:syncing), do: "badge-info"
  defp status_class(:indexing), do: "badge-info"
  defp status_class(:error), do: "badge-error"
  defp status_class(:"not synced"), do: "badge-ghost"

  defp last_error(%{errors: errors}) do
    case List.last(errors) do
      %{"error" => error} -> Format.truncate(error, 400)
      _ -> ""
    end
  end
end
