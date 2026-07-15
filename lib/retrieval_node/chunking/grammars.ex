defmodule RetrievalNode.Chunking.Grammars do
  @moduledoc """
  Thin facade over the `tree_sitter_language_pack` NIF for the set of grammars
  this app needs cached on disk, at both build time (`mix rn.grammars.prefetch`)
  and runtime (`/healthz`'s `grammar_cache` gate).

  ## Required set

  `TreeSitterImpl.allowed_languages/0` (the 7 mainstream code languages actually
  parsed today) plus `"elixir"`, `"heex"`, `"eex"` — prefetched now even though
  `TreeSitterImpl` doesn't chunk them yet, so the cache is already warm when the
  planned native-AST Elixir/HEEx/EEx chunking path lands (fast-follow; see
  `TreeSitterImpl`'s moduledoc). Fetching them early avoids a first-deploy
  surprise where that follow-up ships and only then discovers the grammars
  aren't cached in the target environment.

  ## NIF boundary

  Every function that ultimately calls the NIF (`download/1` via
  `downloaded_languages/0` and `download/1`) goes through the configurable
  `:grammar_pack_mod` (defaults to `TreeSitterLanguagePack`), so tests can swap
  in a stub and stay NIF-free — mirroring the `:chunking_impl` /
  `:embedding_impl` seam pattern already used elsewhere in this app.
  """

  alias RetrievalNode.Chunking.TreeSitterImpl

  require Logger

  # Prefetched ahead of the native-AST Elixir/HEEx/EEx chunking fast-follow —
  # see the moduledoc.
  @extra_languages ~w(elixir heex eex)

  @doc "Languages that must be present in the local grammar cache."
  @spec required() :: [String.t()]
  def required, do: Enum.uniq(TreeSitterImpl.allowed_languages() ++ @extra_languages)

  @doc "Required languages not currently present in the local grammar cache."
  @spec missing() :: [String.t()]
  def missing, do: required() -- pack_mod().downloaded_languages()

  @doc "Whether every required language is already cached locally."
  @spec all_cached?() :: boolean()
  def all_cached?, do: missing() == []

  @doc "Prefetch every required language (see `required/0`)."
  @spec prefetch() :: {:ok, non_neg_integer()} | {:error, atom(), String.t()}
  def prefetch, do: prefetch(required())

  @doc """
  Prefetch the given languages via the NIF's `download/1`, logging a clear line
  per outcome and passing the result through unchanged.
  """
  @spec prefetch([String.t()]) :: {:ok, non_neg_integer()} | {:error, atom(), String.t()}
  def prefetch(languages) when is_list(languages) do
    case pack_mod().download(languages) do
      {:ok, count} = ok ->
        Logger.info("Grammar prefetch: downloaded #{count} language(s): #{inspect(languages)}")
        ok

      {:error, kind, message} = error ->
        Logger.error("Grammar prefetch failed for #{inspect(languages)}: #{kind} — #{message}")

        error
    end
  end

  defp pack_mod,
    do: Application.get_env(:retrieval_node, :grammar_pack_mod, TreeSitterLanguagePack)
end
