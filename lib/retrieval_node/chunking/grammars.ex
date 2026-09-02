defmodule RetrievalNode.Chunking.Grammars do
  @moduledoc """
  Thin facade over the `tree_sitter_language_pack` NIF for the set of grammars
  this app needs cached on disk, at both build time (`mix rn.grammars.prefetch`)
  and runtime (`/healthz`'s `grammar_cache` gate).

  ## Required set

  `TreeSitterImpl.allowed_languages/0` (the 8 languages actually parsed
  today — 7 mainstream code languages plus elixir) plus `"heex"`/`"eex"` —
  prefetched now even though `TreeSitterImpl` doesn't chunk them yet, so the
  cache is already warm when the planned native-AST HEEx/EEx chunking path
  lands (fast-follow; see `TreeSitterImpl`'s moduledoc). Fetching them early
  avoids a first-deploy surprise where that follow-up ships and only then
  discovers the grammars aren't cached in the target environment.
  `@extra_languages` below still lists `"elixir"` too — harmless overlap with
  `allowed_languages/0` that `Enum.uniq/1` in `required/0` dedups away, left
  alone rather than trimmed for what should stay a doc-only change.

  ## NIF boundary

  Every function that ultimately calls the NIF (`download/1` via
  `downloaded_languages/0` and `download/1`) goes through the configurable
  `:grammar_pack_mod` (defaults to `TreeSitterLanguagePack`), so tests can swap
  in a stub and stay NIF-free — mirroring the `:chunking_impl` /
  `:embedding_impl` seam pattern already used elsewhere in this app.
  """

  alias RetrievalNode.Chunking.TreeSitterImpl

  require Logger

  # heex/eex are prefetched ahead of the native-AST chunking fast-follow (see
  # the moduledoc); elixir is listed here too but is redundant now that
  # `TreeSitterImpl.allowed_languages/0` already covers it — `Enum.uniq/1` in
  # `required/0` absorbs the overlap.
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
  @spec prefetch() :: {:ok, term()} | {:error, atom(), String.t()}
  def prefetch, do: prefetch(required())

  @doc """
  Prefetch the given languages via the NIF's `prefetch/1`, logging a clear line
  per outcome and passing the result through unchanged.

  `prefetch/1` (not `download/1`) is load-bearing: the pack's `download/1`
  reports `{:ok, count}` without leaving loadable `.so` grammars in the cache
  dir that `downloaded_languages/0` lists — only `prefetch/1` (download AND
  load into the process registry) extracts the shared libraries. Verified
  empirically on a cold cache: `download/1` → `missing/0` still lists every
  language; `prefetch/1` → `missing/0` is empty. Using `download/1` here made
  `mix rn.grammars.prefetch` always fail on a fresh machine/CI runner — the
  warm dev cache (populated as a side effect of real parsing) masked it.
  """
  @spec prefetch([String.t()]) :: {:ok, term()} | {:error, atom(), String.t()}
  def prefetch(languages) when is_list(languages) do
    case pack_mod().prefetch(languages) do
      {:ok, _} = ok ->
        Logger.info("Grammar prefetch: downloaded + loaded: #{inspect(languages)}")
        ok

      {:error, kind, message} = error ->
        Logger.error("Grammar prefetch failed for #{inspect(languages)}: #{kind} — #{message}")

        error
    end
  end

  defp pack_mod,
    do: Application.get_env(:retrieval_node, :grammar_pack_mod, TreeSitterLanguagePack)
end
