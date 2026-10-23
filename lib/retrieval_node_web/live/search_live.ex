defmodule RetrievalNodeWeb.SearchLive do
  @moduledoc """
  Runs the same hybrid (dense + BM25, RRF) search as the `semantic_search` MCP
  tool and shows the ranked chunks with their content, to judge retrieval
  quality by eye.
  """
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.{Inventory, Search}
  alias RetrievalNodeWeb.SourceLive

  @top_k_options ~w(10 20 50)

  @impl true
  def mount(_params, _session, socket) do
    sources = Enum.map(Inventory.list_sources(), & &1.source)

    {:ok,
     assign(socket,
       page_title: "Search",
       sources: sources,
       source_names: Map.new(sources, &{&1.id, &1.name}),
       source_options: [{"All sources", ""} | Enum.map(sources, &{&1.name, &1.id})],
       top_k_options: @top_k_options
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = Map.get(params, "q", "")
    source_id = Map.get(params, "source", "")
    top_k = if params["top_k"] in @top_k_options, do: params["top_k"], else: "10"

    {:noreply,
     socket
     |> assign(form: to_form(%{"q" => q, "source" => source_id, "top_k" => top_k}))
     |> assign(:results, search(q, source_id, String.to_integer(top_k)))}
  end

  @impl true
  def handle_event("search", params, socket) do
    query =
      params
      |> Map.take(["q", "source", "top_k"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/search?#{query}")}
  end

  defp search(q, source_id, top_k) do
    case String.trim(q) do
      "" ->
        nil

      text ->
        opts = if source_id == "", do: [top_k: top_k], else: [top_k: top_k, source_id: source_id]
        hits = Search.hybrid_search(text, opts)
        chunks = Inventory.chunks_by_id(Enum.map(hits, & &1.chunk.id))

        hits
        |> Enum.with_index(1)
        |> Enum.flat_map(&result(&1, chunks))
    end
  end

  # A hit whose chunk vanished between search and fetch (re-index) is dropped.
  defp result({hit, rank}, chunks) do
    case Map.fetch(chunks, hit.chunk.id) do
      {:ok, chunk} -> [%{rank: rank, score: hit.score, chunk: chunk}]
      :error -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:search}>
      <.form
        for={@form}
        id="search-form"
        phx-submit="search"
        class="grid items-end gap-2 sm:grid-cols-[minmax(0,1fr)_14rem_6rem_auto]"
      >
        <.input field={@form[:q]} type="search" placeholder="Search the index…" autocomplete="off" />
        <.input field={@form[:source]} type="select" options={@source_options} />
        <.input field={@form[:top_k]} type="select" options={@top_k_options} />
        <div class="mb-2">
          <.button variant="primary" phx-disable-with="Searching…">
            <.icon name="hero-magnifying-glass" class="size-4" /> Search
          </.button>
        </div>
      </.form>

      <p :if={@results == []} class="opacity-60">No result.</p>

      <div :if={@results} id="results" class="space-y-4">
        <div :for={r <- @results} id={"result-#{r.chunk.id}"}>
          <div class="mb-1 flex flex-wrap items-center gap-2 text-sm">
            <span class="badge badge-neutral badge-sm tabular-nums">#{r.rank}</span>
            <span class="font-medium">{Map.get(@source_names, r.chunk.source_id, r.chunk.repo)}</span>
            <.link
              :if={file_key(r.chunk)}
              navigate={~p"/sources/#{r.chunk.source_id}?#{[file: file_key(r.chunk)]}"}
              class="link link-hover min-w-0 truncate font-mono text-xs"
            >
              {file_key(r.chunk)}
            </.link>
            <span class="ml-auto text-xs tabular-nums opacity-60">
              score {Float.round(r.score, 4)}
            </span>
          </div>
          <SourceLive.chunk_card chunk={r.chunk} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp file_key(chunk) do
    chunk.metadata["path"] || chunk.metadata["doc_id"] || chunk.metadata["issue_key"]
  end
end
