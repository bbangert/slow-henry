defmodule RetrievalNodeWeb.SourceLive do
  @moduledoc "Files indexed for one source, and the chunks of a selected file."
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.Inventory
  alias RetrievalNodeWeb.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Inventory.get_source(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Unknown source.") |> push_navigate(to: ~p"/")}

      %{source: source, sync: sync} ->
        {:ok, assign(socket, page_title: source.name, source: source, sync: sync)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = Map.get(params, "q", "")
    file = Map.get(params, "file")
    source = socket.assigns.source

    {:noreply,
     assign(socket,
       q: q,
       form: to_form(%{"q" => q}),
       file: file,
       files: Inventory.list_files(source.id, q),
       chunks: if(file, do: Inventory.file_chunks(source.id, file), else: [])
     )}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: source_path(socket.assigns.source, q, socket.assigns.file))}
  end

  defp source_path(source, q, file) do
    query = Enum.reject([q: q, file: file], fn {_k, v} -> v in [nil, ""] end)
    ~p"/sources/#{source.id}?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:sources}>
      <div>
        <.link navigate={~p"/"} class="link link-hover text-sm opacity-70">
          <.icon name="hero-arrow-left-micro" class="size-4" /> Sources
        </.link>
        <h1 class="mt-1 text-2xl font-semibold">
          {@source.name}
          <span class="badge badge-ghost align-middle">{Format.source_type(@source.source_type)}</span>
        </h1>
        <p class="text-sm opacity-70">
          {@source.identifier} · last sync {Format.ago(@sync && @sync.last_synced_at)}
          <span :if={@sync && @sync.cursor["last_sha"]}>
            · <code>{String.slice(@sync.cursor["last_sha"], 0, 10)}</code>
          </span>
        </p>
      </div>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <section>
          <.form for={@form} id="file-filter" phx-change="filter" phx-submit="filter">
            <.input
              field={@form[:q]}
              type="search"
              placeholder="Filter files…"
              phx-debounce="200"
              autocomplete="off"
            />
          </.form>
          <p class="mb-2 text-xs opacity-60">{length(@files)} files</p>
          <ul id="files" class="menu menu-sm w-full rounded-box border border-base-300 p-1">
            <li :for={f <- @files} id={"file-#{:erlang.phash2(f.key)}"}>
              <.link patch={source_path(@source, @q, f.key)} class={[f.key == @file && "menu-active"]}>
                <span class="min-w-0 flex-1 truncate" title={f.key}>{f.name || f.key}</span>
                <span :if={f.fallback > 0} class="badge badge-ghost badge-xs" title="heuristic chunking">
                  fallback
                </span>
                <span :if={f.redacted > 0} class="badge badge-warning badge-xs">redacted</span>
                <span class="text-xs tabular-nums opacity-60">{f.chunks}</span>
              </.link>
            </li>
            <li :if={@files == []} class="p-4 text-center opacity-60">No file.</li>
          </ul>
        </section>

        <section>
          <div :if={!@file} class="rounded-box border border-dashed border-base-300 p-10 text-center opacity-60">
            Select a file to see its chunks.
          </div>

          <div :if={@file}>
            <h2 class="break-all font-mono text-sm font-semibold">{@file}</h2>
            <p class="mb-3 text-xs opacity-60">
              {length(@chunks)} chunks · {Format.bytes(Enum.sum_by(@chunks, &byte_size(&1.content)))}
            </p>
            <div id="chunks" class="space-y-3">
              <.chunk_card :for={c <- @chunks} chunk={c} />
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :chunk, :map, required: true

  def chunk_card(assigns) do
    ~H"""
    <div id={"chunk-#{@chunk.id}"} class="rounded-box border border-base-300">
      <div class="flex flex-wrap items-center gap-2 border-b border-base-300 px-3 py-1.5 text-xs">
        <span class="min-w-0 flex-1 truncate opacity-70" title={@chunk.context_breadcrumb}>
          {@chunk.context_breadcrumb}
        </span>
        <span :if={@chunk.lang} class="badge badge-ghost badge-xs">{@chunk.lang}</span>
        <span :if={@chunk.parse_status != :ok} class="badge badge-ghost badge-xs">
          {@chunk.parse_status}
        </span>
        <span :if={@chunk.secrets_status == :redacted} class="badge badge-warning badge-xs">
          redacted
        </span>
        <span class="tabular-nums opacity-60">{String.length(@chunk.content)} chars</span>
      </div>
      <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-words p-3 text-xs">{@chunk.content}</pre>
    </div>
    """
  end
end
