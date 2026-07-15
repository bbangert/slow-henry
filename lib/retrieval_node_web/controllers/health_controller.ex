defmodule RetrievalNodeWeb.HealthController do
  @moduledoc """
  `GET /healthz` — readiness (not liveness): 200 only once every subsystem this
  node depends on for correct answers is actually usable, 503 with per-gate
  detail otherwise. A process merely being alive (which a liveness probe would
  check) says nothing about whether it can serve a correct MCP response — this
  route is what a load balancer / uptime check should watch instead.

  ## Gates

    * `grammar_cache` — tree-sitter grammars required by `TreeSitterImpl` (see
      `RetrievalNode.Chunking.Grammars`) are present on disk.
    * `nx_backend` — `Nx.default_backend/0` resolved to EXLA, guarding against
      a silent fallback to `Nx.BinaryBackend` (10-100x slower, see
      `design-build.md` §4 step 2).
    * `embedding_warm` — `RetrievalNode.Embedding.Serving.ready?/0`, i.e. the
      warmup dummy inference (JIT compile) has completed.
    * `db` — `RetrievalNode.Repo` can round-trip a trivial query.

  ## Skip rule

  `nx_backend` and `embedding_warm` only matter when the real `Nx.Serving`
  sub-tree is running (`:embedding_serving_start`); `grammar_cache` only
  matters when the configured `:chunking_impl` actually uses the tree-sitter
  NIF. A config-disabled subsystem must not fail readiness for a node that was
  deliberately built without it — those gates report `"skipped"` and count as
  passing.
  """

  use RetrievalNodeWeb, :controller

  alias RetrievalNode.Chunking
  alias RetrievalNode.Chunking.Grammars
  alias RetrievalNode.Embedding.Serving
  alias RetrievalNode.Repo

  def show(conn, _params) do
    checks = %{
      grammar_cache: grammar_cache_check(),
      nx_backend: nx_backend_check(),
      embedding_warm: embedding_warm_check(),
      db: db_check()
    }

    respond(conn, checks)
  end

  defp respond(conn, checks) do
    if ready?(checks) do
      conn |> put_status(:ok) |> json(%{status: "ok", checks: render_checks(checks)})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "error", checks: render_checks(checks)})
    end
  end

  defp ready?(checks),
    do: Enum.all?(checks, fn {_gate, %{status: status}} -> status != :error end)

  defp render_checks(checks),
    do: Map.new(checks, fn {gate, result} -> {gate, render_gate(result)} end)

  defp render_gate(%{status: status, detail: nil}), do: %{status: to_string(status)}

  defp render_gate(%{status: status, detail: detail}),
    do: %{status: to_string(status), detail: detail}

  # --- Gate: grammar_cache ----------------------------------------------

  defp grammar_cache_check do
    if tree_sitter_configured?() do
      case Grammars.missing() do
        [] -> ok()
        missing -> error(%{missing: missing})
      end
    else
      skipped()
    end
  end

  defp tree_sitter_configured?,
    do: chunking_impl() == RetrievalNode.Chunking.TreeSitterImpl

  # --- Gate: nx_backend ---------------------------------------------------

  defp nx_backend_check do
    if embedding_serving_start?() do
      case Nx.default_backend() do
        {EXLA.Backend, _opts} -> ok()
        EXLA.Backend -> ok()
        other -> error(%{backend: inspect(other)})
      end
    else
      skipped()
    end
  end

  # --- Gate: embedding_warm ------------------------------------------------

  defp embedding_warm_check do
    if embedding_serving_start?() do
      if Serving.ready?(), do: ok(), else: error(%{ready: false})
    else
      skipped()
    end
  end

  # --- Gate: db --------------------------------------------------------------

  defp db_check do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> ok()
      {:error, reason} -> error(%{reason: inspect(reason)})
    end
  rescue
    # A gate must never itself 500 the request — normalize any Repo-raised
    # exception (e.g. the pool being down) to a failed gate instead.
    e -> error(%{reason: Exception.message(e)})
  end

  defp chunking_impl, do: Chunking.impl()

  defp embedding_serving_start?,
    do: Application.get_env(:retrieval_node, :embedding_serving_start, true)

  defp ok, do: %{status: :ok, detail: nil}
  defp skipped, do: %{status: :skipped, detail: nil}
  defp error(detail), do: %{status: :error, detail: detail}
end
