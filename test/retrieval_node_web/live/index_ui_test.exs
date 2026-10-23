defmodule RetrievalNodeWeb.IndexUITest do
  use RetrievalNodeWeb.ConnCase, async: true
  use Oban.Testing, repo: RetrievalNode.Repo

  import Phoenix.LiveViewTest

  alias RetrievalNode.Embedding.StubImpl
  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Inventory
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  setup do
    source =
      Repo.insert!(%Source{source_type: :git_repo, name: "adr", identifier: "file:///adr.git"})

    chunk(source, "decisions/0001-staging.md", "Services reach staging through the VPN.")
    chunk(source, "decisions/0001-staging.md", "Production access requires a second approval.")
    chunk(source, "README.md", "Architecture decision records for the team.")

    %{source: source}
  end

  defp chunk(source, path, content, metadata \\ nil) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      repo: source.name,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "hash-#{System.unique_integer([:positive])}",
      content: content,
      context_breadcrumb: path,
      metadata: metadata || %{"path" => path},
      embedding: Pgvector.new(StubImpl.embed(content))
    })
  end

  describe "sources page" do
    test "lists sources with file and chunk counts", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/")

      row = view |> element("#source-#{source.id}") |> render()
      assert row =~ "adr"
      assert row =~ ~r/>\s*2\s*</
      assert row =~ ~r/>\s*3\s*/
    end

    test "a source with staged files shows as indexing", %{conn: conn, source: source} do
      Repo.insert!(%RetrievalNode.Retrieval.PendingChunk{
        source: "git",
        source_id: source.id,
        source_type: "git_repo",
        natural_key: "repo:#{source.id}:lib/a.ex",
        content_hash: "h",
        raw_content: "defmodule A do\nend\n",
        metadata: %{"path" => "lib/a.ex"}
      })

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~r/Sources indexing.*?>\s*1\s*</s
      assert view |> element("#source-#{source.id}") |> render() =~ "indexing"
    end

    test "sync button enqueues a RepoSync for the source", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#sync-#{source.id}") |> render_click() =~ "Sync queued for adr"
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id})
    end
  end

  describe "sync eligibility" do
    test "inactive and denied sources are not enqueued", %{source: source} do
      inactive = Repo.update!(Ecto.Changeset.change(source, active: false))
      denied = Repo.update!(Ecto.Changeset.change(source, active: true, policy: :deny))

      assert {:error, :ineligible} = Inventory.enqueue_sync(inactive)
      assert {:error, :ineligible} = Inventory.enqueue_sync(denied)
      refute_enqueued(worker: RepoSync)
    end

    test "an active allow source is enqueued", %{source: source} do
      assert {:ok, _job} = Inventory.enqueue_sync(source)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id})
    end

    test "the sync button on an inactive source flashes and enqueues nothing", %{
      conn: conn,
      source: source
    } do
      Repo.update!(Ecto.Changeset.change(source, active: false))
      {:ok, view, _html} = live(conn, ~p"/")

      assert render_click(view, "sync", %{"id" => source.id}) =~ "inactive or denied by policy"
      refute_enqueued(worker: RepoSync)
    end
  end

  describe "source page" do
    test "filters files and shows the chunks of the selected file", %{conn: conn, source: source} do
      {:ok, view, html} = live(conn, ~p"/sources/#{source.id}")
      assert html =~ "decisions/0001-staging.md"
      assert html =~ "README.md"

      html = view |> form("#file-filter", %{"q" => "decisions"}) |> render_change()
      assert html =~ "decisions/0001-staging.md"
      refute html =~ "README.md"

      {:ok, _view, html} = live(conn, ~p"/sources/#{source.id}?file=decisions/0001-staging.md")
      assert html =~ "Services reach staging through the VPN."
      assert html =~ "Production access requires a second approval."
      refute html =~ "Architecture decision records"
    end

    test "a file's chunks are shown in chunk_index order, not insertion order", %{
      source: source
    } do
      # Inserted out of document order; a legacy chunk without chunk_index sorts last.
      for {content, index} <- [{"third", 2}, {"legacy", nil}, {"first", 0}, {"second", 1}] do
        metadata =
          if index,
            do: %{"path" => "ordered.md", "chunk_index" => index},
            else: %{"path" => "ordered.md"}

        chunk(source, "ordered.md", content, metadata)
      end

      assert source |> Inventory.file_chunks("ordered.md") |> Enum.map(& &1.content) ==
               ~w(first second third legacy)
    end

    test "redirects home for an unknown source", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/sources/#{Ecto.UUID.generate()}")
    end
  end

  describe "search page" do
    test "shows ranked chunks with their content", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view
      |> form("#search-form", %{"q" => "staging VPN", "source" => source.id, "top_k" => "10"})
      |> render_submit()

      html = render(view)
      assert_patched(view, ~p"/search?#{[q: "staging VPN", source: source.id, top_k: "10"]}")
      assert html =~ "Services reach staging through the VPN."
      assert html =~ "decisions/0001-staging.md"
    end

    test "an invalid source filter shows an error and does not search", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/search?q=anything&source=not-a-uuid")

      assert html =~ "Unknown source filter."
      assert has_element?(view, "#search-form")
      refute has_element?(view, "#results")
      refute render(view) =~ "No result."

      # A later valid search clears the stale error.
      refute render_patch(view, ~p"/search?q=anything") =~ "Unknown source filter."
    end

    test "a 16-byte source filter (castable as a raw UUID) is rejected, not crashed on",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/search?q=anything&source=abcdefghijklmnop")

      assert html =~ "Unknown source filter."
      refute has_element?(view, "#results")
    end
  end

  describe "layout" do
    test "theme toggle buttons have accessible names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for theme <- ~w(system light dark) do
        assert has_element?(
                 view,
                 ~s(button[data-phx-theme="#{theme}"][aria-label="Use #{theme} theme"])
               )
      end
    end
  end
end
