defmodule RetrievalNode.Embedding do
  @moduledoc """
  Behaviour + dispatcher for the swappable embedding seam.

  Resolves the configured implementation (`:embedding_impl`) at call time and
  delegates to it, so call sites (query-time search, bulk indexing) never name a
  concrete impl. Implementations:

    * `RetrievalNode.Embedding.NxServingImpl` — the v1 default: in-process
      Bumblebee/Nx.Serving over nomic-embed-text-v1.5, Matryoshka-truncated to 384.
    * `RetrievalNode.Embedding.LlamaCppSidecarImpl` — a stub escape hatch (HTTP to
      a `llama.cpp --embedding` server) if Bumblebee/EXLA proves unworkable on arm64.

  Vectors are bare `[float()]` (length `dimensions/0`), consumed directly by
  `Pgvector.new/1` in the search/ingest paths.
  """

  @type text :: String.t()
  @type vector :: [float()]

  @doc "Embed a single text into a `dimensions/0`-length vector."
  @callback embed(text) :: vector

  @doc "Embed a batch of texts, returning one vector per input in order."
  @callback embed_batch([text]) :: [vector]

  @doc "The embedding dimensionality (384 after Matryoshka truncation)."
  @callback dimensions() :: pos_integer()

  @doc """
  The configured embedding implementation module.

  Raises a clear `ArgumentError` if the configured `:embedding_impl` module isn't
  loaded (a misconfiguration), rather than letting call sites hit a cryptic
  `UndefinedFunctionError`.
  """
  @spec impl() :: module()
  def impl do
    mod = Application.fetch_env!(:retrieval_node, :embedding_impl)

    unless Code.ensure_loaded?(mod) do
      raise ArgumentError,
            "configured :embedding_impl #{inspect(mod)} is not loaded — check that " <>
              ":embedding_impl points at a compiled module."
    end

    mod
  end

  @doc "Embed a single text into a 384-dim vector (list of floats)."
  @spec embed(String.t()) :: [float()]
  def embed(text), do: impl().embed(text)

  @doc "Embed a batch of texts into 384-dim vectors."
  @spec embed_batch([String.t()]) :: [[float()]]
  def embed_batch(texts), do: impl().embed_batch(texts)

  @doc "Embedding dimensionality (384 after Matryoshka truncation)."
  @spec dimensions() :: pos_integer()
  def dimensions, do: impl().dimensions()
end
