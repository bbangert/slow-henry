# NIF Isolation Design: tree_sitter_language_pack

## Requirement

`tree_sitter_language_pack` (Rustler NIF, no documented panic-safety) runs
inside the chunking step of the Oban ingest pipeline. A malformed/pathological
source file can crash the BEAM VM. The MCP endpoint (`/mcp`, Anubis MCP on
Phoenix) **must** stay up regardless of what happens during ingestion. Ingest
is overnight-batch, not latency-critical, so raw parse throughput is not the
optimization target — containment and operational simplicity are.

## BEAM Architecture Context

- **A NIF panic/segfault is not an Elixir exception.** It corrupts or kills
  the OS process (the BEAM VM instance) that loaded it. No supervisor,
  `try/rescue`, or `:erlang.process_flag(:trap_exit, true)` on *that same
  node* can save you — the whole VM goes down, taking every process on it
  (Endpoint, Oban, Ecto pool, MCP connections) with it.
- Therefore true containment requires the NIF to execute in a **different OS
  process** than the one serving `/mcp`. This is a hard requirement, not a
  style preference — same-node supervision (`Task.Supervisor`,
  `DynamicSupervisor`, `Process.monitor`) only protects against Elixir-level
  crashes (raised exceptions, `exit` signals), not native segfaults.
- Given that, the two realistic architectures are: (a) a **peer BEAM node**
  connected via Erlang distribution, or (b) a **Port-wrapped external OS
  process** speaking a custom stdin/stdout protocol. Both isolate the OS
  process; they differ in how much custom plumbing they need.
- Concurrency need: yes, but only enough to keep the ingest pipeline moving
  in the background — not the MCP query path. Isolation domain: yes, the
  entire point. Shared state: no. Statelessness: parsing itself is a pure
  function of (file content, language) → chunks; the isolation wrapper is
  the only stateful piece (it owns a connection to a subprocess).

## Recommendation

**Process needed**: YES — but the "process" here is a **peer OTP node** (a
second BEAM VM instance), not a GenServer, and not a second deployed service.

**Pattern**: A small, supervised pool of **long-lived peer nodes**, started
programmatically via `:peer` (OTP 25+, the modern replacement for the
deprecated `:slave`) from *within* the same release, dedicated to running
`tree_sitter_language_pack` calls. The parent (main) node talks to them via
`:erpc.call/5` with a hard timeout. A crash or timeout on the peer becomes an
`{:error, reason}` return value in the parent, which the Oban worker turns
into a normal job failure/retry.

### Why peer node over Port + external binary

| | Peer node (`:peer` + `:erpc`) | Port + external Rust/CLI binary |
|---|---|---|
| Isolation guarantee | Same: separate OS process, segfault can't touch parent | Same |
| Protocol | Native Erlang term passing (erpc), zero protocol code | Must design/maintain a framed stdin/stdout wire protocol |
| Code reuse | Same compiled release, same modules, same NIF binary already resolved for the host arch | Must build/ship a **second** standalone binary embedding tree-sitter, duplicating what the Hex package already does |
| Cross-arch story | Piggybacks entirely on however `tree_sitter_language_pack` already resolves per-arch NIFs in the release — nothing new to build for aarch64/x86-64 | New per-arch build/packaging step for the standalone binary |
| Ops surface | Requires Erlang distribution enabled in the release (cookie, node naming) | Requires the extra binary present in the release's `bin/` and executable permissions |
| Team familiarity | Pure OTP — same primitives (`Process.monitor`, supervision) the team already reasons about | New protocol code to write, test, and maintain |

Given the "one release + Postgres" simplicity goal, the peer-node approach
wins: it reuses the release that's already built and already resolves the
NIF for the correct architecture, and needs no new protocol/binary. The Port
approach is a legitimate fallback (see Tradeoffs) if distribution ever proves
operationally awkward.

## Supervision Tree Sketch

```
RetrievalNode.Supervisor (Application root, strategy: :one_for_one)
├── RetrievalNode.Repo
├── RetrievalNodeWeb.Endpoint          # Anubis MCP mounted at /mcp — never touches parser nodes
├── Oban                                # queues: :sync, :chunk, :embed, :upsert (bounded concurrency each)
├── RetrievalNode.Embedding.Serving     # Nx.Serving, unrelated failure domain
└── RetrievalNode.Chunking.NodePool     # Supervisor, strategy: :one_for_one
    ├── RetrievalNode.Chunking.ParserNode  (id: :parser_1)
    └── RetrievalNode.Chunking.ParserNode  (id: :parser_2)   # pool size default 1–2, config-driven
```

`ParserNode` is a GenServer, `restart: :permanent`. Each one:

1. On `init/1`, starts a peer node with `:peer.start_link/1`
   (`name: :"parser_1@127.0.0.1"`, same release code path, minimal apps —
   just `:tree_sitter_language_pack` and its deps, **not** Phoenix/Oban/Ecto,
   keeping the child VM's footprint small).
2. `Process.monitor/1`s the peer's controller process so a peer crash
   arrives as a normal `{:DOWN, ...}` message, not a surprise.
3. Exposes `parse(content, lang, opts \\ [])`, which does:
   ```elixir
   def parse(pid, content, lang, timeout \\ 30_000) do
     GenServer.call(pid, {:parse, content, lang, timeout}, timeout + 1_000)
   end

   def handle_call({:parse, content, lang, timeout}, _from, %{node: node} = state) do
     result =
       try do
         :erpc.call(node, TreeSitter.Isolated, :parse, [content, lang], timeout)
       catch
         :error, {:erpc, :noconnection} -> {:error, :parser_crashed}
         :exit, {:erpc, :timeout} -> {:error, :parser_timeout}
       end

     {:reply, result, state}
   end
   ```
4. On `{:DOWN, _, :process, _, _}` for the monitored peer (i.e. the peer VM
   died — segfault, OOM-kill, whatever), immediately restarts a fresh peer
   node so the pool member is ready for the next job. The GenServer itself
   never crashes; it just replaces its dead child.

## How This Slots Into the Oban Pipeline

```
RepoSync (Oban, queue: :sync)
  → enqueue ChunkFile per changed file (queue: :chunk, low concurrency, e.g. 2)
      ChunkFile.perform/1:
        1. Pre-flight guards (below) — reject/redirect before touching the NIF at all
        2. Checkout a ParserNode (round-robin via Registry, or just
           `Enum.random/1` over configured pool ids — throughput isn't the
           concern)
        3. NodePool.parse(pid, content, lang) with a bounded timeout
        4. case result:
             {:ok, chunks}              -> proceed to EmbedBatch
             {:error, :parser_crashed}  -> raise/return error tuple → Oban
                                           marks job failed, exponential
                                           backoff retry (attempt N)
             {:error, :parser_timeout}  -> same, treated as retryable
        5. On the job's *last* configured attempt (Oban `attempt >=
           max_attempts`), catch that condition explicitly in the worker and
           fall back to the heuristic line-chunker instead of letting the
           job die permanently — the file still gets indexed (never skip
           silently, per existing requirement), and gets flagged
           `parse_status: :crashed_fallback` in the chunk metadata for
           later manual review.
  → EmbedBatch (queue: :embed)
  → UpsertChunks (queue: :upsert)
```

Key containment property: a NIF crash inside a peer node produces a
`{:DOWN, ...}` on the parent's monitor and an `{:erpc, :noconnection}` (or a
hang that then times out) from `:erpc.call`. Nothing about that failure mode
touches the parent node's process table, ETS tables, Ecto pool, or Cowboy
acceptors serving `/mcp`. Concurrent MCP queries in flight during a parser
crash are completely unaffected — they're different processes on a VM that
never went down.

## Tradeoffs vs "One Release + Postgres"

**Does this add a service?** No new *deployed artifact*, no new systemd
unit, no new container. It is the same `mix release` binary, and the peer
nodes are OS processes spawned programmatically by the running application
at startup (or on first chunk job), living for the lifetime of the app, not
managed separately by systemd. Operationally there is still one thing to
`systemctl start/stop/restart`.

**What it does add**, honestly:

- **Erlang distribution must be enabled in the release** — a release
  cookie (`RELEASE_COOKIE` env or `vm.args.eex`), a node name for the main
  node, and either `epmd` running or the release configured for
  static/manual distribution. This is a real piece of new operational
  surface: if the cookie is missing or `epmd` isn't reachable, `:peer.start`
  fails at startup. Mitigate with a startup health check that logs loudly
  (and ideally refuses to silently degrade — surface it) if the parser pool
  fails to come up, since ingest would otherwise fail every job forever.
- **A few extra OS processes at runtime** — each peer node is a full (if
  minimal) BEAM VM: base overhead is roughly 20–40 MB plus whatever code is
  loaded (just the tree-sitter NIF and its deps, not Phoenix/Ecto/Oban). With
  a pool of 1–2, this is tens of MB, comfortably inside "a few GB."
- **A second thing that can be misconfigured across environments** —
  dev (x86) and prod (arm) both need distribution working identically; this
  needs a smoke test (see below), not just "it worked once."

**Is it justified?** Yes. The alternative — running the NIF in-process — has
a confirmed (not hypothetical) crash risk, and a VM crash during an
overnight batch is not merely "the batch fails and retries": it also kills
every concurrent MCP query and requires an external process manager
(systemd `Restart=on-failure`) to bring it back, meaning real (if hopefully
brief) downtime of the one thing this whole app exists to provide. The
peer-node approach avoids that at a modest, well-understood operational
cost using primitives (OTP distribution, monitors, supervision) the team
already reasons about daily.

**Simpler fallback, if the risk is judged acceptable:** Run the NIF
in-process, with pre-flight guards only (size caps, binary detection,
extension allowlist) and a `Task.await(task, timeout)`-based wall-clock
guard. Be explicit about what this does and doesn't buy you: the `Task`
timeout protects against a pathological *hang* (infinite loop in the
grammar), but **cannot** protect against an actual panic/segfault — by the
time the NIF corrupts memory, no supervising Elixir process gets a chance to
react. Given the crash risk here is research-confirmed rather than assumed,
and the corpus is hundreds of thousands of real-world source files (a
long tail of generated code, minified JS, binary-ish files, etc., all
realistic during an overnight batch), this fallback is not recommended as
the primary design — but it's a reasonable **stopgap for the first vertical
slice** while the peer-node pool is being built, since chunking is already
behind a `Chunking` behaviour and swapping the isolation strategy later
doesn't touch call sites.

## Input Pre-Flight Guards (Defense in Depth)

Applied *before* any content reaches the NIF, in-process or isolated —
cheapest possible rejection first:

1. **Size cap**: files above a configurable threshold (e.g. 2 MB) skip
   AST parsing entirely and go straight to the heuristic line-chunker.
   Very large files (generated code, vendored bundles, lockfiles) rarely
   benefit from AST-aware chunking anyway, and are exactly the kind of input
   that stresses a parser most.
2. **Binary detection**: null-byte scan / a cheap MIME/extension sniff
   before attempting to parse; binary blobs are never handed to the parser.
3. **Extension/language allowlist**: only enable grammars for languages
   actually present in the indexed repos (a small subset of the 306 the
   language pack supports), reducing both attack surface and the peer
   node's loaded-grammar memory footprint.
4. **Wall-clock timeout per call**, enforced by `:erpc.call/5`'s timeout
   argument regardless of the isolation layer — catches infinite-loop
   inputs, not just crashes, and turns a hang into a retryable failure
   instead of a stuck queue.
5. **Crash-loop circuit breaker**: track `parse_attempts` /
   `parse_status` per file in the DB. After Oban's `max_attempts` is
   exhausted, stop retrying that file against the AST parser permanently —
   fall back to heuristic chunking and mark it `:crashed_fallback` for an
   admin-visible review list, rather than letting exponential backoff loop
   forever on one bad file each night.
6. **OS-level resource caps** on the peer node processes (ulimit/cgroup
   memory ceiling inherited from the parent systemd unit, or explicit
   `+hms`/heap-size VM args) as a backstop against a pathological input
   causing unbounded memory growth rather than a clean crash.

## aarch64 / x86-64 Parity

- The peer node runs the **same compiled release** as the parent — same
  BEAM bytecode, same already-arch-resolved NIF binary. There is nothing
  isolation-specific to build or package per architecture; whatever
  `tree_sitter_language_pack` already does to resolve/prefetch grammars for
  aarch64 vs x86-64 is unchanged by this design (still run `prefetch()` at
  deploy time on both, per the open item in the interview, so peer nodes
  never attempt a mid-job network download).
- Distribution over short names / localhost (`epmd` or static distribution)
  behaves identically on both hosts — no arch-specific networking config.
- Deploy checklist, identical on both targets: (1) `RELEASE_COOKIE` set,
  (2) `epmd` running (or static distribution configured), (3)
  `tree_sitter_language_pack.prefetch/0` run for the enabled grammar
  allowlist before first ingest.
- Recommended smoke test, runnable identically on dev (x86) and prod (arm):
  boot the app, feed a known pathological/fuzzed input file to the chunker,
  assert (a) the peer node dies, (b) the parent node's `/mcp` endpoint keeps
  answering health checks throughout, (c) the Oban job is marked failed and
  retried, (d) the pool replaces the dead peer node automatically. Same
  test, same assertions, either architecture — proves containment isn't
  arch-dependent rather than assuming it.
