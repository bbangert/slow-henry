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

  Graph extraction (`chunk_with_graph/2`) is tree-sitter-only: it is an
  **optional** callback, implemented only by `TreeSitterImpl` (single parse,
  two consumers — the same tree yields both chunks and graph rows). The
  heuristic fallback path has no AST to walk, so it indexes chunks but
  contributes no entities/references; the dispatcher below wraps its
  `chunk/2` result accordingly rather than erroring.
  """

  alias RetrievalNode.Graph.Extractor

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

  @doc """
  Like `chunk/2`, but also returns graph entities/references extracted from
  the same parse. Optional — only `TreeSitterImpl` implements it.
  """
  @callback chunk_with_graph(source :: String.t(), language :: language) ::
              {:ok,
               %{
                 chunks: [chunk],
                 entities: [Extractor.entity()],
                 references: [Extractor.ref()]
               }}
              | {:error, atom() | {atom(), term()}}

  @optional_callbacks chunk_with_graph: 2

  @spec chunk(String.t(), language) :: {:ok, [chunk]} | {:error, atom() | {atom(), term()}}
  def chunk(source, language), do: impl().chunk(source, language)

  @doc """
  Dispatch to `impl().chunk_with_graph/2` when the configured impl exports it;
  otherwise fall back to `chunk/2` and wrap the result with empty graph lists.
  Errors pass through unchanged either way.
  """
  @spec chunk_with_graph(String.t(), language) ::
          {:ok, %{chunks: [chunk], entities: [Extractor.entity()], references: [Extractor.ref()]}}
          | {:error, atom() | {atom(), term()}}
  def chunk_with_graph(source, language) do
    impl = impl()

    # Code.ensure_loaded?/1 (not just function_exported?/3) is required here:
    # function_exported?/3 answers false for a module that hasn't been loaded
    # yet, even when the function genuinely exists in its compiled form — a
    # fresh boot would otherwise silently drop graph data for the first file
    # this runs against (TreeSitterImpl isn't loaded until some caller touches
    # it), then "start working" once the module happens to get loaded.
    if Code.ensure_loaded?(impl) and function_exported?(impl, :chunk_with_graph, 2) do
      impl.chunk_with_graph(source, language)
    else
      case impl.chunk(source, language) do
        {:ok, chunks} -> {:ok, %{chunks: chunks, entities: [], references: []}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  True if `content` is binary rather than text: contains a NUL byte, or isn't
  valid UTF-8. Shared by the chunking pre-flight guard (`TreeSitterImpl`) and
  the ingest staging seam (`Ingest.PendingChunks`) — staging must catch strictly
  MORE than the chunking guard alone, since a Postgres `text` column rejects any
  invalid UTF-8 outright (error 22021), not just embedded NULs.
  """
  @spec binary_content?(String.t()) :: boolean()
  def binary_content?(content) when is_binary(content),
    do: String.contains?(content, <<0>>) or not String.valid?(content)

  @spec allowed_languages() :: [language]
  def allowed_languages, do: impl().allowed_languages()

  @spec impl() :: module()
  def impl,
    do:
      Application.get_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.TreeSitterImpl)
end
