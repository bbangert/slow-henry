defmodule RetrievalNode.Reranking.Serving do
  @moduledoc """
  Supervised `Nx.Serving` process for cross-encoder/ms-marco-MiniLM-L-6-v2.

  `Nx.Serving` is the OTP-aware abstraction here — batching, batch-timeout and
  backpressure are its runtime reason to exist as a process, so no bespoke
  GenServer wrapper is needed. `NxServingImpl` builds `{query, passage}` pairs
  and truncates oversized passages before handing them to this serving; the
  serving itself emits one raw relevance logit (`%{score: float}`) per pair, in
  order.

  ## A query-time-only serving

  Unlike `RetrievalNode.Embedding.Serving` (which serves both interactive
  query embeds and bulk indexing batches), this serving only ever sees the
  query path: one `batched_run/2` call per search request, reranking a
  handful of top-K retrieval candidates (tens of pairs, not thousands). There
  is no bulk/background caller competing for its batch queue, so the model
  (~91 MB, far smaller than the ~1.2 GB embedding model) is cheap to keep
  warm dedicated to this single purpose.

  ## Warmup

  `Nx.Serving.child_spec/1`'s `:compile` option runs a template-shaped EXLA
  compile pass synchronously inside its `init`, forcing the expensive JIT
  during `Supervisor.start_link/2` rather than on the first real request.
  `warmup/0` is additional defense: it runs a real dummy inference through the
  full pipeline and flips a `:persistent_term` readiness flag consumed by
  `/healthz`. If warmup crashes it logs and lets the next real call pay the
  JIT cost inline — never take down boot over a best-effort optimization.

  Warmup itself is driven by a sibling `RetrievalNode.Reranking.Warmer`
  GenServer under `RetrievalNode.Reranking.Supervisor`, a `:rest_for_one`
  supervisor ordered `[Serving, Warmer]`. `handle_continue` in the Warmer
  defers the actual `warmup/0` call until after its own `init/1` returns, so
  boot is never blocked on model load/JIT. `rest_for_one` is the reason this
  process doesn't fire `Task.start/1` on its own: if this serving crashes and
  restarts, the readiness flag must go stale (`false`) again until a fresh
  warmup completes, and `rest_for_one` restarting the Warmer alongside it is
  what makes that happen automatically — a `one_for_one` sibling would never
  re-run warmup, leaving `/healthz` reporting `ready? == true` against a
  serving that just rebuilt its state from scratch.
  """

  require Logger

  alias RetrievalNode.Reranking.NxServingImpl

  @name RetrievalNode.Reranking.ServingProcess

  @doc "The registered name of the serving process."
  def name, do: @name

  def child_spec(_opts) do
    serving =
      Bumblebee.Text.cross_encoding(
        model_info(),
        tokenizer(),
        compile: [batch_size: batch_size(), sequence_length: sequence_length()],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.child_spec(serving: serving, name: @name, batch_timeout: batch_timeout())
    |> Supervisor.child_spec(id: @name)
  end

  @doc """
  Dummy inference through the full pipeline, forcing EXLA JIT before real
  traffic and flipping the `/healthz` readiness flag. Fire-and-forget; never
  raises out.

  Goes through `NxServingImpl.rerank_scores/2` (not a raw
  `Nx.Serving.batched_run/2`) so warmup exercises the exact same passage
  truncation production calls do. Calling the concrete impl module directly
  (rather than the generic `Reranking` facade) is deliberate: warmup is
  inherently about this serving process specifically, and only ever runs
  where `NxServingImpl` is configured (`:reranking_serving_start` is false
  everywhere else). A misconfigured serving then fails loudly here instead of
  silently flipping `ready?` on a malformed result.
  """
  def warmup do
    scores = NxServingImpl.rerank_scores("warmup", ["warmup passage"])

    unless match?([score] when is_float(score), scores) do
      raise "warmup rerank returned #{inspect(scores)}, expected a single-element list of float"
    end

    :persistent_term.put({__MODULE__, :ready?}, true)
    :ok
  rescue
    e ->
      Logger.error(
        "Reranking warmup failed: #{inspect(e)} — first real request will pay JIT cost"
      )

      :error
  catch
    # batched_run is a GenServer.call — a not-yet-registered serving or a call
    # timeout surfaces as an exit, which `rescue` does not catch. Handle it here
    # so warmup logs and returns cleanly instead of crashing the Task. `ready?`
    # stays false (the put above never ran), which is the correct polarity.
    :exit, reason ->
      Logger.error(
        "Reranking warmup exited: #{inspect(reason)} — first real request will pay JIT cost"
      )

      :error
  end

  @doc "Whether warmup has completed (consumed by /healthz). Defaults to false."
  def ready?, do: :persistent_term.get({__MODULE__, :ready?}, false)

  @doc """
  Clear the readiness flag back to `false`. Called by `Reranking.Warmer`'s
  `init/1`, before it re-runs `warmup/0`, so `/healthz` never reports stale
  `true` for the window between a serving restart and the next warmup
  completing.
  """
  def reset_ready, do: :persistent_term.put({__MODULE__, :ready?}, false)

  defp model_info, do: load!(:model, &Bumblebee.load_model/1)
  defp tokenizer, do: load!(:tokenizer, &Bumblebee.load_tokenizer/1)

  # Bumblebee.load_model/load_tokenizer return {:ok, _} | {:error, _}; unwrap with
  # a clear error so a missing/incompatible model fails loudly at boot.
  defp load!(kind, loader) do
    case loader.({:hf, model_repo()}) do
      {:ok, loaded} ->
        loaded

      {:error, reason} ->
        raise "failed to load reranking #{kind} for #{inspect(model_repo())}: #{inspect(reason)}"
    end
  end

  defp config, do: Application.get_env(:retrieval_node, __MODULE__, [])
  defp model_repo, do: Keyword.fetch!(config(), :model)
  defp batch_size, do: Keyword.fetch!(config(), :batch_size)
  defp sequence_length, do: Keyword.fetch!(config(), :sequence_length)
  defp batch_timeout, do: Keyword.fetch!(config(), :batch_timeout_ms)
end
