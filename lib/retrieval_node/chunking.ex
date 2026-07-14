defmodule RetrievalNode.Chunking do
  @moduledoc """
  Behaviour + dispatcher for splitting a source blob into embeddable chunks.

  The swappable seam (config `:chunking_impl`) has two v1 implementations:

    * `RetrievalNode.Chunking.TreeSitterImpl` — AST-boundary chunking via the
      tree-sitter NIF, for the allowlisted languages. Guarded (size/binary/
      language pre-flight + a supervised `Task` timeout) so a slow or crashing
      parse degrades to an error tuple, never takes down the caller.
    * `RetrievalNode.Chunking.HeuristicImpl` — a pure-Elixir line/blank-line/
      brace-balance chunker with no NIF involvement. The pipeline's fallback impl
      and the `:test`-env default (keeps the suite NIF-free).

  `chunk/2` is **pure dispatch** — it delegates to the configured impl and returns
  whatever that impl returns, including `{:error, reason}`. It does NOT itself
  fall back. The fallback *orchestration* — deciding which error reasons re-run
  through `HeuristicImpl` (`:chunk_timeout`/`:chunk_crashed`/`:unsupported_language`)
  versus skip the file (`:too_large`/`:binary_content`) — lives in the ingest
  worker (`Ingest.Workers.ChunkFiles`, Phase 6). That worker only ever calls
  `chunk/2`, never the NIF directly, so promoting to the peer-node isolation
  escape hatch later is a config change plus one module, not a call-site rewrite.
  """

  @type language :: String.t()
  @type chunk :: %{
          text: String.t(),
          breadcrumb: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          kind: String.t(),
          parse_status: :ok | :heuristic_fallback | :crashed_fallback
        }

  @doc "Split `source` (in `language`) into chunks, or return a tagged error."
  @callback chunk(source :: String.t(), language :: language) ::
              {:ok, [chunk]} | {:error, atom() | {atom(), term()}}

  @doc "The languages this implementation can chunk (tree-sitter allowlist)."
  @callback allowed_languages() :: [language]

  @spec chunk(String.t(), language) :: {:ok, [chunk]} | {:error, atom() | {atom(), term()}}
  def chunk(source, language), do: impl().chunk(source, language)

  @spec allowed_languages() :: [language]
  def allowed_languages, do: impl().allowed_languages()

  @spec impl() :: module()
  def impl,
    do:
      Application.get_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.TreeSitterImpl)
end
