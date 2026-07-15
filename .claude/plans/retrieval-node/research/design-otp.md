# OTP Design: retrieval_node

Status: v1 design per interview contract. Peer-node (`:peer`) isolation for the
chunker NIF was proposed in prior research (`nif-isolation-design.md`) and is
**OVERRULED for v1** by the pinned decision in `interview.md`. This document
designs **Option C**: in-process parsing, guarded by pre-flight checks + a
per-call `Task` wall-clock timeout, running on whatever scheduler the NIF
itself declares (dirty or not — see §3). Peer-node/subprocess isolation
remains a documented **future escape hatch only** (§3.4), not built now, with
the `Chunking` behaviour as the seam that makes swapping to it later a
config change, not a rewrite.

**Cross-doc note:** `design-build.md` §3–4 (systemd unit, startup sequence)
still references a "peer-node parser pool" and `RELEASE_COOKIE`/Erlang
distribution as load-bearing for chunking isolation. That predates this
decision and should be corrected when that doc is next touched: v1 needs
**no** Erlang distribution, no peer nodes, and no cross-node cookie — Option C
is entirely in-process. Flagging here so the inconsistency doesn't propagate
into the plan uncorrected.

---

## 1. Application supervision tree

```
RetrievalNode.Supervisor  (Application root, strategy: :one_for_one)
├── RetrievalNode.Repo                          # Ecto/Postgres+pgvector pool
├── {Phoenix.PubSub, name: RetrievalNode.PubSub}
├── RetrievalNode.Finch                         # Finch pool: Jira REST + Drive API + (future) llama.cpp sidecar
├── {Task.Supervisor, name: RetrievalNode.ChunkTaskSupervisor}   # bounded async wrapper for chunk calls (§3)
├── RetrievalNode.Embedding.Serving             # Nx.Serving child (nomic-embed-text-v1.5), warmed at boot (§2)
├── {Oban, Application.fetch_env!(:retrieval_node, Oban)}         # ingest pipeline (queues: :sync, :chunk, :embed, :upsert)
└── RetrievalNodeWeb.Endpoint                   # Anubis MCP Plug mounted at /mcp + health routes
```

```elixir
defmodule RetrievalNode.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RetrievalNode.Repo,
      {Phoenix.PubSub, name: RetrievalNode.PubSub},
      {Finch, name: RetrievalNode.Finch},
      {Task.Supervisor, name: RetrievalNode.ChunkTaskSupervisor},
      RetrievalNode.Embedding.Serving,
      {Oban, Application.fetch_env!(:retrieval_node, Oban)},
      RetrievalNodeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RetrievalNode.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Fire-and-forget defensive warmup pass (§2) — Nx.Serving's own
      # `:compile` option already forces JIT during its child init, so this
      # is belt-and-suspenders, not the primary warmup mechanism.
      Task.start(fn -> RetrievalNode.Embedding.Serving.warmup() end)
      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    RetrievalNodeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

**Strategy**: `:one_for_one` at the top level — every listed child is an
independent failure domain (§5). No child's crash should restart a sibling:
Endpoint crashing has no bearing on Oban job state or the embedder; Oban
crashing has no bearing on in-flight MCP requests.

**Ordering rationale** (why this order, not alphabetical):

1. **`Repo`** first — everything downstream (Oban, Ingest workers, Search
   queries, Endpoint request handlers) needs a DB connection eventually;
   Ecto's own pool internally supervises individual connections, so this
   entry is just "the pool exists before consumers try to use it."
2. **`Phoenix.PubSub`** — required by Phoenix even without LiveView; cheap,
   no coupling beyond "before Endpoint."
3. **`Finch`** — one shared HTTP client pool for all outbound calls (Jira
   REST, Google Drive API, and the llama.cpp sidecar HTTP client *if* that
   embedding impl is ever swapped in). Started before Oban since `:sync`
   queue jobs use it immediately.
4. **`Task.Supervisor` (chunk tasks)** — must exist before any Oban `:chunk`
   job runs, since `ChunkFiles` workers call
   `Task.Supervisor.async_nolink(RetrievalNode.ChunkTaskSupervisor, ...)`.
5. **`Embedding.Serving`** — started before Oban so EXLA JIT warmup runs
   concurrently with the rest of boot (Oban queue producers spinning up,
   Endpoint accepting its first connections) rather than serializing after
   everything else. Ingest jobs calling `Nx.Serving.batched_run/2` before
   warmup finishes still work correctly (Nx.Serving queues/executes
   normally) — ordering here is a latency optimization, not a correctness
   dependency.
6. **`Oban`** — after every service its jobs might call (`Repo`, `Finch`,
   `ChunkTaskSupervisor`, `Embedding.Serving`).
7. **`Endpoint`** last — the layer that generates the most external load,
   started once the pipeline it depends on for background ingest is already
   up (the MCP query path itself only depends on `Repo` + `Embedding.Serving`
   for `semantic_search`, both already running).

No child ever explicitly blocks on another's readiness at supervision-tree
init time (no gating child, no health-check gate baked into `start/2`) —
readiness is instead exposed via a `/healthz` route (§2, §6) so an external
process manager / load balancer can distinguish "BEAM is up" from "actually
ready to serve," without slowing down `Supervisor.start_link/2` itself.

---

## 2. Embedding subsystem

### 2.1 Nx.Serving child + warmup

```elixir
defmodule RetrievalNode.Embedding.Serving do
  @moduledoc """
  Supervised Nx.Serving process for nomic-embed-text-v1.5, Matryoshka-truncated
  to 384 dims at inference time. `Nx.Serving` is the OTP-aware abstraction here
  (batching + timeout + backpressure are its runtime reason to exist as a
  process) — no bespoke GenServer wrapper needed.
  """

  @name RetrievalNode.Embedding.ServingProcess

  def child_spec(_opts) do
    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info(), tokenizer(),
        compile: [batch_size: batch_size(), sequence_length: sequence_length()],
        defn_options: [compiler: EXLA],
        output_attribute: :hidden_state,
        # ⚠️ output_pool is REQUIRED with :hidden_state (nomic uses masked mean
        # pooling). An earlier revision of this sketch omitted it and shipped a
        # real bug: the serving emits the full padded {seq_len, 768} hidden-state
        # sequence per text instead of one pooled {768} embedding; downstream
        # Matryoshka truncation then flattens it to seq_len*384 floats — and at
        # sequence_length 512 that is 196,608 = 3×65,536, which overflows
        # pgvector's uint16 dimension header to exactly 0 ("vector must have at
        # least 1 dimension"). Caught only by the real-model :integration tests.
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm
      )

    Nx.Serving.child_spec(serving: serving, name: @name, batch_timeout: batch_timeout())
    |> Supervisor.child_spec(id: @name)
  end

  def name, do: @name

  @doc "Dummy inference through the full pipeline, forcing EXLA JIT before real traffic."
  def warmup do
    Nx.Serving.batched_run(@name, ["warmup"])
    :persistent_term.put({__MODULE__, :ready?}, true)
    :ok
  rescue
    e ->
      require Logger
      Logger.error("Embedding warmup failed: #{inspect(e)} — first real request will pay JIT cost")
      :error
  end

  def ready?, do: :persistent_term.get({__MODULE__, :ready?}, false)

  defp batch_size, do: Application.get_env(:retrieval_node, __MODULE__)[:batch_size]
  defp sequence_length, do: Application.get_env(:retrieval_node, __MODULE__)[:sequence_length]
  defp batch_timeout, do: Application.get_env(:retrieval_node, __MODULE__)[:batch_timeout_ms]
  defp model_info, do: ...
  defp tokenizer, do: ...
end
```

**Why warmup doesn't block the Endpoint**: `Nx.Serving.child_spec/1`'s
`:compile` option already performs a template-shaped EXLA compile pass
*synchronously inside its own `init`*, before the Serving process reports
"started" to its supervisor — this alone forces the expensive JIT compile
during `Supervisor.start_link/2`, not on first real request. The `warmup/0`
call from `Application.start/2` (via unsupervised `Task.start/1`, deliberately
fire-and-forget) is additional defense: it runs a real dummy inference through
the *full* pipeline (tokenizer → model → normalization), catching anything the
shape-only compile pass might miss, and flips a `:persistent_term` readiness
flag consumed by `/healthz` (§6). Using `Task.start/1` here — one of the very
few defensible unsupervised spawns in the system — is intentional: warmup has
no state and no restart semantics; if it crashes, log and let the next real
`embed_query`/`embed_batch` call eat the JIT cost inline (correct, just slow
once), rather than taking down `Application.start/2` over a
best-effort optimization.

**Gating readiness, not gating startup**: the Endpoint accepts connections
immediately; MCP `semantic_search` calls issued before `warmup/0` completes
simply experience the 10–30s ARM JIT stall on that first real call. If tighter
control is wanted later, `Tools.semantic_search/1` can check
`Embedding.Serving.ready?/0` and return a `"warming up, retry shortly"` tool
error instead of blocking — deferred as a v1.1 refinement, not built now,
since the interactive query path is expected to be rare during the first
seconds after a restart.

### 2.2 The `Embedding` behaviour

```elixir
defmodule RetrievalNode.Embedding do
  @moduledoc "Behaviour + facade for text -> vector embedding. Swappable via config, not code change."

  @type text :: String.t()
  @type vector :: [float()]

  @callback embed_query(text) :: {:ok, vector} | {:error, atom()}
  @callback embed_batch([text]) :: {:ok, [vector]} | {:error, atom()}
  @callback dimensions() :: pos_integer()

  def embed_query(text), do: impl().embed_query(text)
  def embed_batch(texts), do: impl().embed_batch(texts)
  def dimensions, do: impl().dimensions()

  defp impl, do: Application.get_env(:retrieval_node, :embedding_impl, RetrievalNode.Embedding.NxServingImpl)
end
```

- **`RetrievalNode.Embedding.NxServingImpl`** — the v1 implementation.
  `dimensions/0` returns `384` (Matryoshka-truncated). `embed_query/1` and
  `embed_batch/1` both call `Nx.Serving.batched_run(Serving.name(), texts)`;
  the only difference is arity of the input list (1 vs N).
- **`RetrievalNode.Embedding.LlamaCppSidecarImpl`** — stub for v1, HTTP client
  over the shared `RetrievalNode.Finch` pool to a `llama.cpp --embedding`
  server, same behaviour contract. Documents the fallback if Bumblebee/EXLA
  proves unworkable on the arm64 target (per `exla-aarch64.md`); swappable via
  `config :retrieval_node, :embedding_impl, RetrievalNode.Embedding.LlamaCppSidecarImpl`
  with zero call-site changes anywhere in `Ingest` or `Search`.

### 2.3 Interactive (query-time) vs batch (indexing) embedding: same serving

**Decision: one `Nx.Serving` process, not two.** Rationale:

- `Nx.Serving` already exists to solve exactly this coexistence problem: it
  internally batches concurrent `batched_run/2` calls arriving within
  `batch_timeout` (configured here at 50ms) up to `batch_size`, regardless of
  whether the caller is a single interactive `semantic_search` query (batch of
  1) or an `EmbedBatch` Oban job submitting tens of chunk texts at once
  (batch of N up to `batch_size`). A second, separate serving process would
  duplicate the loaded model in memory (doubling the ~1.2 GB footprint,
  materially eating into the "few GB RAM" budget) for a problem `Nx.Serving`
  already solves via batching.
- The one real tension — a bulk `EmbedBatch` job submitting a large batch
  could add latency to a concurrent interactive query waiting on the same
  serving — is bounded by two existing decisions in `design-oban.md`: the
  `:embed` Oban queue runs at **concurrency 1**, and each `EmbedBatch` job's
  batch size is capped at "tens of chunks per job" (file/issue/doc-scoped, not
  unbounded). A single in-flight batch of ~20-50 short texts adds low-single-
  digit-ms of queueing to a concurrent query-time request, not the seconds of
  JIT stall that only ever happens once at cold start.
- If this tension is ever measured to matter in practice (query p99 creeping
  up during active ingest), the escape hatch is a **second named `Nx.Serving`
  process sharing the same compiled model artifact but a separate batch
  queue** (Bumblebee model loading is the expensive/duplicated part; the
  `Nx.Serving.child_spec` itself is cheap) — not a redesign, just adding a
  second child under `RetrievalNode.Embedding.Serving`'s supervision with a
  distinct `:name`, and routing `embed_query/1` to it via config. Not built in
  v1; the single-serving design is the simpler default until measurement says
  otherwise.

---

## 3. Chunking subsystem

### 3.1 The `Chunking` behaviour

```elixir
defmodule RetrievalNode.Chunking do
  @moduledoc "Behaviour + facade for source-to-chunks splitting."

  @type language :: String.t()
  @type chunk :: %{
          text: String.t(),
          breadcrumb: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          kind: atom(),
          parse_status: :ok | :heuristic_fallback | :crashed_fallback
        }

  @callback chunk(source :: String.t(), language :: language) ::
              {:ok, [chunk]} | {:error, atom()}
  @callback allowed_languages() :: [language]

  def chunk(source, language), do: impl().chunk(source, language)
  def allowed_languages, do: impl().allowed_languages()

  defp impl, do: Application.get_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.TreeSitterImpl)
end
```

Three implementations, in the fallback order `Ingest.Workers.ChunkFiles`
actually drives (per `design-oban.md` §5):

1. **`RetrievalNode.Chunking.TreeSitterImpl`** — `tree_sitter_language_pack`,
   AST-boundary chunking on function/module/class nodes with bundled `tags`
   queries. Primary path for all allowlisted languages.
2. **`RetrievalNode.Chunking.ElixirAstImpl`** — native
   `Code.string_to_quoted/2` + Sourceror enrichment, used only for `.ex`/`.exs`
   source to keep docs/typespecs attached to their defs; wraps/augments
   `TreeSitterImpl`'s output for Elixir files rather than replacing the
   chunking pass outright (open question #3 in the interview: whether this
   ships in v1 or v1.1 — the behaviour seam means the decision doesn't block
   the rest of the design either way).
3. **`RetrievalNode.Chunking.HeuristicImpl`** — pure-Elixir line/blank-line
   chunker, zero NIF involvement. Used when: (a) size cap rejects a file
   before it ever reaches the NIF, (b) binary detection rejects a file, (c)
   language isn't in the allowlist, (d) `TreeSitterImpl` returns `{:error,
   :chunk_timeout}` or `{:error, {:chunk_crashed, _}}` on an Oban job's final
   attempt (per the `ChunkFiles` worker pattern in `design-oban.md`).

### 3.2 Where the guard/timeout wrapper lives

```elixir
defmodule RetrievalNode.Chunking.TreeSitterImpl do
  @behaviour RetrievalNode.Chunking

  @max_bytes Application.compile_env(:retrieval_node, [:chunking, :max_bytes], 2_000_000)
  @call_timeout_ms Application.compile_env(:retrieval_node, [:chunking, :call_timeout_ms], 5_000)

  @impl true
  def chunk(source, language) when is_binary(source) do
    with :ok <- check_size(source),
         :ok <- check_binary_content(source),
         :ok <- check_language_allowlist(language) do
      run_guarded(source, language)
    end
  end

  defp run_guarded(source, language) do
    task =
      Task.Supervisor.async_nolink(RetrievalNode.ChunkTaskSupervisor, fn ->
        TreeSitterLanguagePack.parse(source, language)
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, chunks}} -> {:ok, chunks}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :chunk_timeout}
      {:exit, reason} -> {:error, {:chunk_crashed, reason}}
    end
  end

  defp check_size(bin) when byte_size(bin) > @max_bytes, do: {:error, :too_large}
  defp check_size(_), do: :ok

  defp check_binary_content(bin), do: if(String.contains?(bin, <<0>>), do: {:error, :binary_content}, else: :ok)

  defp check_language_allowlist(lang) do
    if lang in RetrievalNode.Chunking.allowed_languages(), do: :ok, else: {:error, :unsupported_language}
  end
end
```

**Dedicated GenServer/pool: not warranted here.** Per the "no process without
a runtime reason" rule — a chunk call is stateless per invocation (no shared
state, no serialized resource, no cross-call coordination), so the
already-existing `RetrievalNode.ChunkTaskSupervisor` (started once in the
top-level tree, §1) is the correct and sufficient primitive:
`Task.Supervisor.async_nolink/2` + `Task.yield/2` + `Task.shutdown/2` gives
bounded, supervised, one-off async work per call — exactly the shape this
workload has. A GenServer or worker pool would add restart-state bookkeeping
for zero actual state and a mailbox bottleneck for work that's naturally
parallel across Oban's own `:chunk` queue concurrency (2, per
`design-oban.md`).

`async_nolink` (not `async`) is the essential detail: it prevents an abnormal
task exit from propagating a linked-process exit signal to the calling Oban
job process, so a chunk crash surfaces as `{:error, {:chunk_crashed, reason}}`
in the caller instead of also killing the Oban job process itself.

### 3.3 The "dirty scheduler" honesty

Whether `tree_sitter_language_pack`'s Rust NIF entry point is declared
`#[rustler::nif(schedule = "DirtyCpu")]` is a property of that library's
source, not something `retrieval_node` can force from the calling side —
there is no BEAM-level "call this dirty" mechanism available to a caller.
What this design **does** control is: (a) input guards that reject the
inputs most likely to cause pathological runtime before they ever reach the
NIF, and (b) a wall-clock `Task` timeout that bounds a *hang*. **Confirm
during implementation** whether the NIF is actually dirty-scheduled
(inspect the crate source, or benchmark via
`:erlang.statistics(:scheduler_wall_time)` under a deliberately slow parse);
if it is not, every call runs on a regular BEAM scheduler thread and a
long/hung parse degrades the whole node's scheduling fairness, not just the
calling process — this raises the priority of promoting to the peer-node
escape hatch (§3.4) sooner rather than later.

**What this cannot catch, stated plainly**: `Task.yield/2` +
`Task.shutdown/2` catch hangs and ordinary Elixir-level exceptions/exits. They
do **not** catch a segfault — a segfault takes the entire BEAM OS process
down immediately, taking `/mcp`, Oban, and every other subtree in §1 with it,
simultaneously and unrecoverably from inside the VM. The only mitigation
available under Option C is *outside* the VM: `systemd Restart=on-failure`
(per `design-build.md` §3), which bounds downtime to "however long a fresh
boot + embedding warmup takes," not zero.

### 3.4 The seam for the future peer-node escape hatch

Because every caller (`Ingest.Workers.ChunkFiles`) only ever calls
`RetrievalNode.Chunking.chunk/2` — never `TreeSitterLanguagePack.parse/2`
directly, and never anything peer-node-specific — promoting to the
`nif-isolation-design.md` architecture later is a **config change plus one new
module**, not a call-site rewrite:

```elixir
# future, NOT built in v1:
config :retrieval_node, :chunking_impl, RetrievalNode.Chunking.PeerNodeImpl
```

`RetrievalNode.Chunking.PeerNodeImpl` would implement the same `@behaviour
RetrievalNode.Chunking` contract, internally dispatching to a
`RetrievalNode.Chunking.NodePool` (a `Supervisor` of `:peer`-started BEAM
peer processes reached via `:erpc.call/5`, exactly as sketched in
`nif-isolation-design.md`) instead of an in-process `Task`. The trigger to
build it: a segfault under Option C observed in production telemetry/crash
dumps (per the interview's edge-case note) — not built preemptively, since it
requires enabling Erlang distribution (`RELEASE_COOKIE`, node naming) that
Option C does not need at all.

---

## 4. Context module boundaries

```
lib/retrieval_node/
  ingest/            # Oban workers + source clients + GitMirror facade; owns Repo, SyncState, Chunk schemas
  chunking/          # behaviour + 3 impls (§3) — no Repo access
  embedding/         # behaviour + 2 impls + Nx.Serving child (§2) — no Repo access
  search/            # hybrid RRF query (owns no schemas, reads Ingest's Chunk)
  tools.ex           # thin orchestration for the 4 MCP tool handlers
lib/retrieval_node_web/
  endpoint.ex        # mounts Anubis MCP Plug at /mcp
  mcp/server.ex      # Anubis.Server registration
  mcp/tools/*.ex     # 4 Anubis components — call Tools.*, nothing else
```

**Cross-context rule**: `Tools` never touches `Repo`, `Chunking`, or
`Embedding` directly — it calls `Search` and `Ingest` public functions only.
`Ingest` and `Search` are the only contexts that own Ecto schemas / query
`Repo`. `Chunking` and `Embedding` are pure(ish) service contexts with no
schemas and no `Repo` access, invoked *by* `Ingest`'s Oban workers.

### `RetrievalNode.Ingest`

Owns: `Ingest.Source`, `Ingest.Chunk`, `Ingest.SyncState`, `Ingest.SecretFinding`
schemas (per `design-ecto.md`); the `pending_chunks` staging table; the Oban
worker DAG (`RepoSync`/`JiraSync`/`DriveSync` → `ChunkFiles` → `EmbedBatch` →
`UpsertChunks`, per `design-oban.md`); source clients (`Ingest.Sources.Git`
wrapping `git`/mirror management, `Ingest.Sources.Jira` over Finch,
`Ingest.Sources.Drive` over Finch); and `Ingest.GitMirror` (the `rg`/`git`
shell-out facade used by the `grep`/`get_file` tools, per `design-mcp.md` §4).

Public API:

```elixir
def list_repos() :: [Ingest.Source.t()]
def get_repo(id :: term()) :: {:ok, Ingest.Source.t()} | {:error, :not_found}
def register_repo(attrs :: map()) :: {:ok, Ingest.Source.t()} | {:error, Ecto.Changeset.t()}
def default_ref(repo :: String.t()) :: String.t()
def enqueue_ingest(source_id :: term()) :: {:ok, Oban.Job.t()} | {:error, term()}
def list_documents(source_id :: term()) :: [map()]
def upsert_chunks(source_id :: term(), chunks :: [map()]) :: {:ok, [Ingest.Chunk.t()]} | {:error, term()}
```

(`Ingest.GitMirror.grep/2` and `.show/3` are called directly by `Tools`, since
they're a facade over a stateless local-disk read, not a schema-owning
operation — see `design-mcp.md` §4 for the full module.)

### `RetrievalNode.Chunking` / `RetrievalNode.Embedding`

Public APIs as specified in §2.2 / §3.1. Called only from `Ingest`'s Oban
worker bodies (`ChunkFiles`, `EmbedBatch`) and, for `Embedding.embed_query/1`
specifically, from `Search.hybrid_search/2` at query time.

### `RetrievalNode.Search`

Owns no new schemas — reads `Ingest.Chunk` via Ecto (the RRF CTE query, per
`design-ecto.md` §7).

```elixir
def hybrid_search(query_text :: String.t(), opts :: keyword()) ::
      {:ok, [%{chunk: map(), score: float()}]} | {:error, term()}
```

Internally: `Embedding.embed_query/1` on `query_text`, then
`HybridQuery.search/1` (pgvector cosine CTE + Postgres FTS CTE, RRF-fused,
`k = 60`). `opts` include `:source`, `:repo`, `:lang`, `:top_k`.

### `RetrievalNode.Tools`

```elixir
def semantic_search(params :: map()) :: {:ok, [map()]} | {:error, term()}
def grep(params :: map()) :: {:ok, [map()]} | {:error, term()}
def get_file(params :: map()) :: {:ok, map()} | {:error, term()}
def list_repos() :: {:ok, [map()]} | {:error, term()}
```

Delegates to `Search.hybrid_search/2`, `Ingest.GitMirror.grep/2`,
`Ingest.GitMirror.show/3`, and `Ingest.list_repos/0` respectively (full
implementation in `design-mcp.md` §4.2). The four Anubis `MCP.Tools.*`
components (`SemanticSearch`, `Grep`, `GetFile`, `ListRepos`) are 2-4 line
pass-throughs that translate Anubis's validated param map into one `Tools.*`
call and translate the `{:ok, _} | {:error, _}` result into
`{:reply, Response.json/error(...), frame}` — no business logic lives in the
`mcp/tools/*.ex` layer itself.

---

## 5. Failure domains

Top-level `:one_for_one` gives five independent subtrees:

1. **Endpoint / MCP subtree** — `RetrievalNodeWeb.Endpoint` (Anubis MCP rides
   the Endpoint's own acceptor pool, not a separate supervisor). A crash here
   restarts only the Endpoint; Oban keeps consuming jobs, the embedding
   serving process is untouched.
2. **Oban subtree** — its own internal supervisor/queue producers. A crashed
   job process or queue producer restart doesn't touch Endpoint or
   `Embedding.Serving`.
3. **Embedding subtree** — `RetrievalNode.Embedding.Serving`. If EXLA/the
   backing NIF crashes on a bad input, this child restarts under
   `:one_for_one` without affecting Endpoint or Oban (in-flight Oban jobs
   awaiting `batched_run/2` get an error/timeout and retry via Oban's own
   policy — an application-level concern, not a supervision-tree defect).
4. **Chunk-task subtree** — `RetrievalNode.ChunkTaskSupervisor`. A chunk
   `Task` timing out or exiting abnormally is caught by `async_nolink` +
   `Task.yield/shutdown` (§3.2); the calling Oban job process never crashes
   from this, nor does any other subtree.
5. **Finch subtree** — `RetrievalNode.Finch`. Independent of everything else;
   a pool crash (rare) restarts the HTTP client pool without touching DB,
   embedding, or chunk-task state.

**Where the boundary does not hold — stated plainly**: a genuine segfault in
`tree_sitter_language_pack`'s C core is a **process-level (BEAM VM) crash**,
not a BEAM-process crash. No Elixir/OTP supervision strategy in this tree
catches it, because the failure happens below the level BEAM's fault
isolation operates at (BEAM isolates *Erlang processes* from each other; it
cannot isolate itself from a crash inside a NIF's native code, which executes
in the same OS process and address space as the VM). The only mitigation in
Option C is outside the VM entirely: `systemd Restart=on-failure` (per
`design-build.md` §3). This residual risk is exactly what the (overruled-for-
v1) peer-node architecture (§3.4) would eliminate, at the cost of
`:erpc`/distribution overhead and materially higher operational complexity —
it remains the documented next step if segfaults are actually observed.

---

## 6. Config: config.exs vs runtime.exs

### `config.exs` (compile-time / static defaults, same across dev+prod unless overridden)

```elixir
import Config

config :retrieval_node,
  ecto_repos: [RetrievalNode.Repo]

config :retrieval_node, RetrievalNodeWeb.Endpoint,
  render_errors: [formats: [json: RetrievalNodeWeb.ErrorJSON]],
  pubsub_server: RetrievalNode.PubSub

# Behaviour-seam defaults — overridable per-env, but these are the v1 choice
config :retrieval_node, :chunking_impl, RetrievalNode.Chunking.TreeSitterImpl
config :retrieval_node, :embedding_impl, RetrievalNode.Embedding.NxServingImpl

config :retrieval_node, :chunking,
  max_bytes: 2_000_000,
  call_timeout_ms: 5_000,
  allowed_languages: ~w(elixir heex eex python javascript typescript go rust ruby java)

config :retrieval_node, RetrievalNode.Embedding.Serving,
  model: "nomic-ai/nomic-embed-text-v1.5",
  sequence_length: 512,
  batch_timeout_ms: 50

config :retrieval_node, Oban,
  queues: [sync: 3, chunk: 2, embed: 1, upsert: 5]

import_config "#{config_env()}.exs"
```

Everything here is safe to bake into the release at build time: it doesn't
vary by which physical host runs the release, only by which *environment*
(`dev`/`test`/`prod`) — the arch-specific and secret-bearing values below are
runtime, not compile-time, because they genuinely differ per deploy target
(arm-prod vs x86-dev vs CI) or must never be baked into a versioned artifact.

### `runtime.exs` (evaluated at boot, on the actual host)

```elixir
import Config

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")

  config :retrieval_node, RetrievalNode.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "20"))

  config :retrieval_node, RetrievalNodeWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true

  # MCP endpoint auth (bearer token) — mandatory once internet-exposed
  # (interview: LAN-only/no-auth is a *slice-only* simplification)
  config :retrieval_node, :mcp_bearer_token, System.get_env("MCP_BEARER_TOKEN")

  # Embedder: batch size tuned smaller on the modest-RAM arm64 box than a
  # beefier x86 dev/CI machine might use.
  config :retrieval_node, RetrievalNode.Embedding.Serving,
    batch_size: String.to_integer(System.get_env("EMBED_BATCH_SIZE", "8"))

  # Source credentials — never compiled into the release
  config :retrieval_node, :jira,
    base_url: System.fetch_env!("JIRA_BASE_URL"),
    api_token: System.fetch_env!("JIRA_API_TOKEN"),
    project_key: System.fetch_env!("JIRA_PROJECT_KEY")

  config :retrieval_node, :drive,
    service_account_json: System.fetch_env!("DRIVE_SERVICE_ACCOUNT_JSON_PATH"),
    allowlisted_folder_ids: System.fetch_env!("DRIVE_FOLDER_ALLOWLIST") |> String.split(",")

  config :retrieval_node, :chunking,
    max_bytes: String.to_integer(System.get_env("CHUNK_MAX_BYTES", "2000000")),
    call_timeout_ms: String.to_integer(System.get_env("CHUNK_TIMEOUT_MS", "5000"))
else
  # dev/test: local Postgres, no credentials required, x86 defaults
  config :retrieval_node, RetrievalNode.Repo,
    url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/retrieval_node_dev")

  config :retrieval_node, RetrievalNode.Embedding.Serving, batch_size: 16

  if config_env() == :test do
    # NIF-free in tests, per design-otp.md §3.1 fallback note
    config :retrieval_node, :chunking_impl, RetrievalNode.Chunking.HeuristicImpl
  end
end
```

### What's `config.exs` vs `runtime.exs`, and why

| Concern | Where | Why |
|---|---|---|
| DB adapter/repo module registration | `config.exs` | structural, same every env |
| DB URL, pool size | `runtime.exs` | secret + host-dependent (`DATABASE_URL` differs dev/CI/prod) |
| Oban queue *names* | `config.exs` | structural, always the same four queues |
| Oban queue *concurrency numbers* | `config.exs` (defaults) but override-able via `runtime.exs` if a smaller arm box needs to dial `:chunk`/`:embed` down further than the x86 dev default | tuning value, not a secret, but host-capacity-dependent |
| Embedder model name, sequence length, batch timeout | `config.exs` | fixed product decision (nomic-embed-text-v1.5 @384d), not per-host |
| Embedder **batch size** | `runtime.exs` | RAM-budget-dependent: smaller on the arm64 "few GB" prod box than an x86 dev machine, so it's read from an env var per host rather than hardcoded |
| Chunking guards (size cap, timeout) defaults | `config.exs` | product decision, stable default |
| Chunking guards **override** | `runtime.exs` (env var) | lets ops tighten/loosen without a rebuild if the guard proves mistuned on real repos |
| Chunking/embedding **impl module** (behaviour seam) | `config.exs` default, `runtime.exs`/release-config override possible | the whole point of the behaviour: swap `TreeSitterImpl`→future peer-node impl, or `NxServingImpl`→`LlamaCppSidecarImpl`, via config only |
| Jira token, Drive service-account path/OAuth secret, Drive folder allowlist | `runtime.exs` only, sourced from env/`EnvironmentFile` | secrets — must never be compiled into a versioned release artifact; the allowlist itself is also the explicit data-sharing boundary and must be auditable/changeable without a rebuild |
| MCP bearer token | `runtime.exs` | secret; also only mandatory once internet-exposed (interview's LAN-only slice simplification is dev/test-time, not a `config.exs` default) |
| MCP mount path (`/mcp`) | `config.exs` (Endpoint plug declaration itself) | structural, not a runtime toggle |
| `XLA_TARGET_PLATFORM` | **neither** `config.exs` nor `runtime.exs` — a build-time **shell env var** consumed by the `xla` hex dep's `mix compile` step, per `design-build.md` §1 step 4 | it affects which precompiled binary is fetched at compile time, not app runtime config; setting it in `runtime.exs` would have no effect since compilation already happened |
| Grammar prefetch allowlist | `config.exs` (the language list itself, shared between build-time `prefetch()` invocation and runtime `Chunking.allowed_languages/0`) | must stay identical between the build step (`design-build.md` §1 step 5) and the runtime guard (§3.2) — drift here means a language passes the allowlist guard but has no prefetched grammar, forcing a mid-job network fetch that data-sovereignty and arm64-build rules both forbid |

### arm-prod vs x86-dev deltas, summarized

- **EXLA**: prod sets `batch_size: 8` (RAM-conscious) via `EMBED_BATCH_SIZE`;
  dev defaults to `16` since a dev laptop has RAM to spare and faster
  iteration matters more than memory economy. Both run the same warmup
  path (§2.1) — dev doesn't skip warmup, since catching a broken EXLA
  install locally is cheap and worth doing identically to prod (per
  `design-build.md` §5).
- **Chunking prefetch**: mandatory hard-fail-on-missing-grammar startup check
  in prod (`design-build.md` §4 step 1); dev tolerates lazy on-demand grammar
  download/compile on first use (acceptable pause during iteration, never
  acceptable mid-batch in prod).
- **Oban queue concurrency**: `config.exs` defaults (`chunk: 2, embed: 1`)
  assume a modest 2-4 core arm64 box; if a dev machine has more cores to
  spare, this is not typically raised in dev since dev doesn't run a
  representative ingest volume — no override needed by default, but the
  numbers are `runtime.exs`-overridable per host if a benchmark ever
  demonstrates a different box needs different values.
- **Secrets/credentials**: entirely absent in dev/test (`runtime.exs`'s `else`
  branch requires none), sourced from `EnvironmentFile=-/etc/retrieval_node/env`
  in prod (per `design-build.md` §3) — never hardcoded, never in `config.exs`.
