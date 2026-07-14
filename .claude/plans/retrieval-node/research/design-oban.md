# Oban Pipeline Design — retrieval_node

Plain OSS Oban (no Oban Pro). Target: a few GB RAM, modest CPU (assume 2-4 cores),
single BEAM node running both the ingestion pipeline and the Anubis MCP Plug HTTP
endpoint.

**Note on parsing isolation**: this design uses **option C** from
`nif-isolation-design.md` — in-process `tree_sitter_language_pack` parsing on
a dedicated dirty scheduler, guarded by pre-flight checks and a `Task`
wall-clock timeout. It deliberately does **not** use the peer-BEAM-node pool
(option A) — that is the documented *escape hatch*, adopted only if a real
segfault is observed in production, not the v1 default. The `Task.await`
pattern below catches hangs, not segfaults; a true C-level segfault still
takes the whole node down, mitigated only by guards + monitoring, not
eliminated (per the interview's honest caveat).

## 1. Worker DAG

```
RepoSync   (:sync)  ─┐
JiraSync   (:sync)  ─┼─▶ ChunkFiles (:chunk) ─▶ EmbedBatch (:embed) ─▶ UpsertChunks (:upsert)
DriveSync  (:sync)  ─┘
```

Cron entrypoints (`RepoSync`/`JiraSync`/`DriveSync`) are per-source watermark-driven
"discover work" jobs. Each one diffs against a stored watermark (git SHA, JQL
`resolutiondate`, Drive changes-API `pageToken`/cursor), then for every changed
unit of content it does **not** hand large content through Oban args — it writes
a lightweight staging row and enqueues a downstream job keyed by that row's id.

### Staging table: `pending_chunks`

Because Oban args must be small and JSON-safe (Iron Law 2 & 6), raw extracted text
(git file content, Jira issue body, exported Drive markdown) is written to a
`pending_chunks` table between `*Sync` and `ChunkFiles`, and again holds the
chunked-but-not-yet-embedded text between `ChunkFiles` and `EmbedBatch`:

```
pending_chunks
  id            bigserial PK
  source        text            -- "git" | "jira" | "drive"
  natural_key   text            -- "repo:<id>:<path>" | "jira:<issue_key>" | "drive:<file_id>"
  content_hash  text            -- sha256 of raw content, dedup / change-detection
  raw_content   text            -- pre-chunk (file body / issue text / markdown)
  chunk_index   integer null    -- set once ChunkFiles splits raw_content
  chunk_content text null       -- set once ChunkFiles splits raw_content
  status        text            -- "raw" | "scrubbed" | "chunked" | "embedded"
  scrub_mode    text null       -- "gitleaks" | "gitleaks_degraded_regex" | "regex" -- observability, see §5.1
  chunk_quality text null       -- "tree_sitter" | "heuristic_fallback"
  embedding     vector(768) null
  inserted_at / updated_at
```

`RepoSync`/`JiraSync`/`DriveSync` insert rows with `status: "raw"` via
`Ecto.Multi` + `Oban.insert_all` (one `Multi` per sync run: bulk-insert
`pending_chunks` rows, then bulk-insert one `ChunkFiles` job per **file/issue/doc**
— not per chunk, since chunking happens inside `ChunkFiles`).

### Secrets scrubbing placement

**Decision: fused into `ChunkFiles` as an in-process pre-step, not a separate
Oban worker/queue.** Rationale:

- The content is already loaded into memory/on disk for `ChunkFiles` to parse —
  adding a separate `ScrubSecrets` worker would mean an extra DB round-trip and
  an extra job-table row for a check that's cheap relative to parsing/embedding.
- `git diff` scrubbing via `gitleaks` (`System.cmd/3`) only applies to the
  `"git"` source; Jira/Drive text uses a small in-process Elixir regex scanner
  with no external process — no reason to isolate that in its own queue.
- Keeping it inline lets a single job's retry/backoff cover the whole
  scrub→chunk→enqueue sequence without inventing a second retry policy.

#### 5.1 Corrected scrub semantics (fail-closed, redact-and-proceed)

**This is the one place a prior draft of this document got the policy wrong,
and it's worth stating precisely because it's security-relevant.** `gitleaks
detect` exit codes mean:

- **exit 0** — no secrets found. Proceed with `raw_content` unchanged.
- **exit 1** — secrets **were found**. This is *expected operation*, not a
  failure. Per `secrets-scrubbing.md`'s pinned v1 policy ("redact in-place +
  audit-log row + proceed — never silently index a plaintext secret,
  redacted chunks stay useful"), the correct behavior is: parse gitleaks'
  JSON report, **redact each finding's span in-place** (`[REDACTED:type]`),
  write an `audit_log` row per finding (`natural_key`, `secret_type`,
  `line_range`, `commit_sha`, `timestamp`), set `pending_chunks.scrub_mode =
  "gitleaks"`, and **continue chunking the redacted content**. It must
  **not** `{:cancel, ...}` or otherwise drop the file just because a secret
  was detected — detection-and-redaction is the whole point of the step, and
  discarding on every hit would silently blind the index to any file that
  ever touched a credential, which is worse than redacting it.
- **any other exit code / `System.cmd` raising `ErlangError` (`:enoent`,
  etc.)** — the tool itself is broken (binary missing, unexpected crash).
  This is the actual failure case, and is where **fail-closed** applies:
  content must never proceed to `ChunkFiles`'/`EmbedBatch` unscanned.
  Degrade to the regex-only scanner (still a real scan, just a weaker one)
  rather than skipping scrubbing outright, set `scrub_mode =
  "gitleaks_degraded_regex"`, and **emit a loud, non-log-only signal** —
  a telemetry event / metric increment (`[:retrieval_node, :scrub,
  :degraded]`), not just `Logger.warning`, since a silently-swallowed
  warning defeats the "never silently index unscanned content" intent even
  if the regex fallback technically still runs. An operator dashboard/alert
  on that telemetry event is how "fail closed" stays honest in an
  always-degrade-don't-block design: the operator finds out gitleaks is
  broken promptly, rather than discovering months later that every file for
  a quarter was only regex-scanned.
- If the regex scanner itself cannot run (a genuine Elixir exception, not "it
  found nothing") — that's a real bug, `{:error, reason}` → normal Oban
  retry. If retries exhaust with the regex scanner unable to run at all, the
  file is discarded (`{:cancel, "scrub unavailable, refusing to index
  unscanned content"}`) rather than silently passed through — this is the
  actual fail-closed terminal state, reserved for "no scan of any kind
  succeeded," not for "a scan succeeded and found something."

The corrected `scrub/1` implementation (§7) reflects this.

### Worker responsibilities

| Worker | Queue | Args | Enqueues next |
|---|---|---|---|
| `RepoSync` | `:sync` | `%{"repo_id" => id}` | bulk-insert `pending_chunks` (raw) + one `ChunkFiles` job per changed file, via `Ecto.Multi` |
| `JiraSync` | `:sync` | `%{"project_key" => key}` | same, one `ChunkFiles` job per resolved issue |
| `DriveSync` | `:sync` | `%{"drive_id" => id}` | same, one `ChunkFiles` job per changed/exported doc |
| `ChunkFiles` | `:chunk` | `%{"pending_chunk_id" => id}` | scrub (redact-in-place, see §5.1) -> tree-sitter chunk -> write chunk rows back to `pending_chunks` (splits the raw row into N chunk rows sharing `natural_key`) -> one `EmbedBatch` job per file/issue/doc with `%{"pending_chunk_ids" => [ids]}` |
| `EmbedBatch` | `:embed` | `%{"pending_chunk_ids" => [ids]}` | `Nx.Serving.batched_run/2` over all chunk texts in the batch -> writes `embedding` column on those rows -> enqueues `UpsertChunks` with the same id list |
| `UpsertChunks` | `:upsert` | `%{"pending_chunk_ids" => [ids]}` | idempotent `ON CONFLICT` bulk upsert into the permanent `chunks` table, then deletes the now-consumed `pending_chunks` rows |

Full sketches for every worker (including the `ChunkFiles` NIF-timeout/fallback
pattern and the `UpsertChunks` conflict clause) are below in section 7.

## 2. Queues, concurrency, plugins

| Queue | Concurrency | Rationale |
|---|---|---|
| `:sync` | 3 | I/O-bound (git fetch, Jira/Drive HTTP). Low concurrency is fine — these are cheap "discover work" jobs, not the bottleneck. Bounded so 3 simultaneous git fetches/API polls can't saturate the network stack or file handles. |
| `:chunk` | 2 | **CPU-bound + NIF.** `tree_sitter_language_pack` runs in-process on a dedicated dirty CPU scheduler with a per-call `Task.await/2` timeout (per the v1 isolation decision — option C, not the peer-node escape hatch). BEAM typically allocates dirty-CPU schedulers ≈ `System.schedulers_online()`, capped; on a modest 2-4 core box there are only 1-2 dirty CPU schedulers available in practice. Concurrency of 2 lets chunking make progress without monopolizing every dirty scheduler slot, leaving headroom for other NIF/dirty work and for the regular schedulers serving MCP requests. |
| `:embed` | **1** | **CPU-bound Nx.Serving batching — the queue most directly at odds with "must not starve the MCP endpoint."** See §2.1 below for why concurrency 1 is necessary but not, by itself, sufficient — the shared-vs-separate-serving decision matters as much as the queue limit. |
| `:upsert` | 5 | Plain Postgres I/O (`ON CONFLICT` upserts) — cheap, no CPU contention concern, higher concurrency safely drains the tail of the pipeline. |

```elixir
config :retrieval_node, Oban,
  repo: RetrievalNode.Repo,
  queues: [
    sync: 3,
    chunk: 2,
    embed: 1,
    upsert: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 14},   # 14 days of job history
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", RetrievalNode.Workers.RepoSync,  args: %{"repo_id" => "primary"}},
       {"0 * * * *",    RetrievalNode.Workers.JiraSync,  args: %{"project_key" => "PROJ"}},
       {"*/30 * * * *", RetrievalNode.Workers.DriveSync, args: %{"drive_id" => "shared_drive_1"}}
     ]}
  ]
```

**Repo (Ecto) pool sizing:** `pool_size >= num_queues + sum(queue_limits) + buffer`
= `4 + (3+2+1+5) + buffer` → recommend **`pool_size: 20`** (leaves ~9 connections
of headroom for Phoenix/MCP request handling and ad-hoc `Repo` calls outside
Oban, on a box that can spare it; drop to 15 if Postgres connection limits are
tight).

`Lifeline` at 20 minutes is chosen because the longest legitimate job
(`ChunkFiles` on a large file, worst case a few dirty-scheduler-timeout retries)
should never legitimately run that long — anything still "executing" past 20
minutes is orphaned (node crash / dirty scheduler wedge) and should be rescued.

### 2.1 `embed: 1` is necessary but not sufficient — the shared-serving gap

Concurrency 1 on `:embed` stops multiple `EmbedBatch` *jobs* from piling up
CPU contention against each other and against the regular schedulers serving
`/mcp`. But it does **not**, by itself, guarantee an interactive
`semantic_search` query embedding call (issued from the MCP tool handler,
outside Oban entirely) never waits behind a large bulk `EmbedBatch` call —
**if both paths call `Nx.Serving.batched_run/2` against the same named
`Nx.Serving` process**, a large in-flight ingest batch (tens of chunks) can
hold that serving's dispatch queue long enough to add real latency to a
concurrent interactive query.

**Recommendation**: run **two separate `Nx.Serving` instances** for the same
model — `Embedding.BulkServing` (called only by `EmbedBatch`) and
`Embedding.QueryServing` (called only by the MCP tool's query-time embed
step) — each its own named process with its own `batch_size`/`batch_timeout`
and its own dispatch queue. Both still compete for the same underlying
CPU/EXLA compute (this is unavoidable on one box), but they no longer share
one serialized dispatch queue, so a big ingest batch can't literally block
an interactive request behind it in the same queue — the OS scheduler can
still interleave the two servings' actual tensor-op work fairly, whereas one
shared serving would process requests strictly in submission order. This is
a small addition to the supervision tree (`Embedding.QueryServing` alongside
`Embedding.BulkServing`, or `Embedding.Serving` per source noted in
`nif-isolation-design.md`'s supervision sketch — that document already shows
one `RetrievalNode.Embedding.Serving`; split it into two named children under
the same `Chunking`-adjacent supervisor), not a new deployed artifact.

## 3. Cron schedules (watermark-based incremental sync)

| Worker | Cron | Rationale |
|---|---|---|
| `RepoSync` | `*/15 * * * *` | Git commits land frequently during active dev hours; a bare-mirror `git fetch` + diff is cheap (no full clone), so polling every 15 min keeps latency low without meaningfully loading the box. This is the **fallback** poll — webhooks (§8) are the primary, near-instant trigger; this cron exists purely to bound the worst case if a webhook is missed. Overlapping runs for the same repo (cron vs. webhook, or cron vs. cron) are prevented by the `unique` constraint (section 4), not by the cron interval itself. |
| `JiraSync` | `0 * * * *` (hourly) | Resolved-issue reindexing is not latency-critical (ingestion is explicitly "overnight/batch, not latency-critical"); JQL `resolutiondate >= -7d` watermark means an hourly cadence still catches every resolution well within the 7-day window with wide margin, and avoids hammering the Jira REST API/rate limits. |
| `DriveSync` | `*/30 * * * *` | Google's Changes API is cheap to poll (cursor-based, no expensive query) but Doc exports (Docs -> markdown) are the actual cost; 30 min balances freshness against not re-exporting docs that are mid-edit. |

All three are also safe to trigger on-demand (e.g. a manual "resync now" admin
action or the webhook path below) since they carry no per-invocation state
beyond the static args above — the watermark lives in the DB, not in job args.

## 4. Unique-job constraints

| Worker | `unique` keys | Period / states | Prevents |
|---|---|---|---|
| `RepoSync` | `keys: [:repo_id]` | `{10, :minutes}`, `[:available, :scheduled, :executing]` | Overlapping fetch/diff runs for the same repo if cron fires again before the previous run finishes, or a webhook races the cron (§8). |
| `JiraSync` | `keys: [:project_key]` | `{5, :minutes}`, `[:available, :scheduled, :executing]` | Duplicate JQL polls for the same project. |
| `DriveSync` | `keys: [:drive_id]` | `{5, :minutes}`, `[:available, :scheduled, :executing]` | Duplicate Changes-API polls for the same drive. |
| `ChunkFiles` | `keys: [:pending_chunk_id]` | `{1, :hour}`, `[:available, :scheduled, :executing]` | The real "webhook storm" case: if a fast-moving repo/issue/doc gets touched multiple times within one sync-cycle overlap, or a retry-storm re-enqueues the same file, only one chunk job per `pending_chunks` row is live at a time. |
| `EmbedBatch` | `keys: [:pending_chunk_ids]` | `{30, :minutes}`, `[:available, :scheduled, :executing]` | Duplicate embedding of the exact same batch (defensive; `ChunkFiles` only enqueues one `EmbedBatch` per file, but this guards against replay). |
| `UpsertChunks` | `keys: [:pending_chunk_ids]` | `{30, :minutes}`, `[:available, :scheduled, :executing]` | Duplicate upsert enqueue for the same batch — belt-and-suspenders on top of the `ON CONFLICT` idempotency in section 6, since the unique constraint avoids wasted work even though a double-run would be harmless. |

Note: `unique` on `args` by default hashes the whole args map (`fields: [:worker,
:queue, :args]`); since all args above are just IDs, this is safe and matches
Iron Law 2/4 (no structs, string keys).

## 5. Retry / backoff strategy

| Worker | `max_attempts` | Backoff | Notes |
|---|---|---|---|
| `RepoSync` / `JiraSync` / `DriveSync` | 5 | Oban default exponential | Transient network/API failures (git remote unreachable, Jira/Drive rate limit `429`). A `429` should return `{:snooze, seconds}` (parsed from `Retry-After` if present) rather than counting against `max_attempts`. **UNVERIFIED**: this assumes OSS Oban does not increment `attempt` on snooze — confirm against the installed `oban` version's docs/CHANGELOG before relying on it (no `deps/oban` exists yet to check directly in this greenfield repo). This does not implicate Iron Law 7 (that's a Pro Smart Engine-specific attempt-rollback wrinkle; this design is plain OSS `Oban.Worker`), but the underlying "does snooze touch attempt" behavior should still be verified for the pinned version rather than assumed. |
| `ChunkFiles` | 5 | Custom, short: `trunc(:math.pow(attempt, 2)) + :rand.uniform(5)` seconds | NIF timeouts on a dirty scheduler are usually transient contention (another chunk job or the embedding serving briefly saturating the scheduler), not a permanent defect — short backoff lets it retry quickly rather than waiting the default minutes-long exponential curve. |
| `EmbedBatch` | 3 | Oban default | Nx.Serving failures (OOM on a bad batch, model load hiccup) — fewer attempts because repeatedly re-running the same CPU-heavy batch against a serving that's already struggling is more likely to make things worse than better; after 3 attempts it dies and is visible in the job table for investigation rather than silently retried forever. |
| `UpsertChunks` | 5 | Oban default | Ordinary transient Postgres errors (connection blip, deadlock) — plain retry is correct since the upsert is idempotent (section 6). |

### `ChunkFiles`: NIF timeout -> retry -> heuristic fallback on last attempt

The key pattern requested: a NIF timeout must be **retryable**, but the
**final** attempt must not die — it must fall back to heuristic line-chunking
and still complete the pipeline. This means checking `job.attempt >=
job.max_attempts` *inside* the rescue/catch, not just letting Oban's discard
behavior apply. This is also what actually bounds the "one pathological file
retried forever" risk in this design: because `ChunkFiles` is diff-driven
(only enqueued when `content_hash` changes, per the `RepoSync`/`JiraSync`/
`DriveSync` watermark logic), a file whose content is unchanged is never
re-enqueued at all; and a file whose content *does* keep changing but keeps
failing to parse is capped at 5 attempts **per occurrence** before falling
back to heuristic chunking and completing — so it is never retried
indefinitely within one occurrence, and never re-attempted at all across
occurrences unless the content genuinely changes again. (If a specific
file/language combination proves chronically pathological across many
distinct content changes, that's a signal to add it to the language
allowlist exclusions in `nif-isolation-design.md`'s pre-flight guards, not
something this per-job retry policy needs to solve on its own.)

```elixir
defmodule RetrievalNode.Workers.ChunkFiles do
  use Oban.Worker,
    queue: :chunk,
    max_attempts: 5,
    unique: [period: {1, :hour}, keys: [:pending_chunk_id],
             states: [:available, :scheduled, :executing]]

  alias RetrievalNode.Ingestion.{Scrubber, TreeSitterChunker, HeuristicChunker, PendingChunks}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(45)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_id" => id}, attempt: attempt, max_attempts: max}) do
    row = PendingChunks.fetch!(id)

    with {:ok, scrubbed} <- scrub(row) do
      case run_tree_sitter(scrubbed, attempt: attempt) do
        {:ok, chunks} ->
          PendingChunks.write_chunks(row, chunks, mode: :tree_sitter)
          enqueue_embed_batch(row, chunks)
          :ok

        {:error, :nif_timeout} when attempt >= max ->
          fallback!(row)

        {:error, :nif_crash} when attempt >= max ->
          fallback!(row)

        {:error, reason} ->
          # not the last attempt yet -- let Oban retry with the custom backoff
          {:error, reason}
      end
    else
      {:error, :scrub_unavailable} -> {:cancel, "scrub unavailable, refusing to index unscanned content"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback!(row) do
    chunks = HeuristicChunker.line_chunk(row.raw_content)
    PendingChunks.write_chunks(row, chunks, mode: :heuristic_fallback)
    enqueue_embed_batch(row, chunks)
    :ok
  end

  defp run_tree_sitter(content, attempt: _attempt) do
    task = Task.async(fn -> TreeSitterChunker.chunk(content) end)

    case Task.yield(task, :timer.seconds(30)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, chunks}} -> {:ok, chunks}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :nif_timeout}
    end
  rescue
    _ -> {:error, :nif_crash}
  catch
    :exit, _ -> {:error, :nif_crash}
  end

  # See §5.1: exit 0 = clean, exit 1 = findings (redact + proceed, NOT a failure),
  # anything else = tool broken (degrade to regex, alert loudly; fail-closed only
  # if no scan of any kind can run at all).
  defp scrub(%{source: "git"} = row) do
    case System.cmd("gitleaks",
           ["detect", "--no-git", "--source", "-", "--report-format", "json",
            "--report-path", "/tmp/gitleaks-#{row.id}.json"],
           stdin: row.raw_content, stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, row.raw_content}

      {_out, 1} ->
        findings = read_gitleaks_report!(row.id)
        redacted = Scrubber.redact(row.raw_content, findings)
        PendingChunks.write_audit_log(row, findings, scrub_mode: "gitleaks")
        {:ok, redacted}

      {out, code} ->
        # gitleaks binary missing/broken (e.g. :enoent surfaces via System.cmd
        # raising, or an unexpected non-0/1 exit) -- degrade to the regex
        # scanner rather than fail the job outright, but make the degradation
        # LOUD (telemetry, not just a log line) per §5.1.
        require Logger
        Logger.warning("gitleaks unavailable (exit #{code}): #{out}; degrading to regex scan")
        :telemetry.execute([:retrieval_node, :scrub, :degraded], %{count: 1}, %{repo_id: row.natural_key})
        degrade_to_regex(row)
    end
  rescue
    ErlangError ->
      :telemetry.execute([:retrieval_node, :scrub, :degraded], %{count: 1}, %{repo_id: row.natural_key})
      degrade_to_regex(row)
  end

  defp scrub(row), do: regex_scrub(row)

  defp degrade_to_regex(row) do
    case regex_scrub(row) do
      {:ok, redacted} -> {:ok, redacted}
      # regex scanner is pure Elixir and shouldn't itself fail; if it does,
      # nothing scanned this content at all -- true fail-closed terminal state.
      {:error, _} -> {:error, :scrub_unavailable}
    end
  end

  defp regex_scrub(row) do
    findings = Scrubber.regex_scan(row.raw_content)
    redacted = Scrubber.redact(row.raw_content, findings)
    if findings != [], do: PendingChunks.write_audit_log(row, findings, scrub_mode: "regex")
    {:ok, redacted}
  rescue
    _ -> {:error, :regex_scan_failed}
  end

  defp read_gitleaks_report!(id) do
    "/tmp/gitleaks-#{id}.json" |> File.read!() |> Jason.decode!()
  end

  defp enqueue_embed_batch(row, chunks) do
    ids = PendingChunks.chunk_ids_for(row, chunks)

    %{"pending_chunk_ids" => ids}
    |> RetrievalNode.Workers.EmbedBatch.new()
    |> Oban.insert()
  end
end
```

`HeuristicChunker.write_chunks(..., mode: :heuristic_fallback)` tags the
resulting chunk rows (`chunks.chunk_quality = "heuristic"` in the final table)
so downstream consumers/observability can tell degraded chunks apart from
tree-sitter-parsed ones without losing the content entirely — the Iron Law
here is "never skip the file," which the fallback satisfies.

## 6. `UpsertChunks` idempotency

Assume the permanent `chunks` schema has a natural key
`(source, natural_key, chunk_index)` plus a `content_hash` column (sha256 of
the chunk text) used for change-detection, and a unique index:

```sql
CREATE UNIQUE INDEX chunks_natural_key_idx
  ON chunks (source, natural_key, chunk_index);
```

```elixir
defmodule RetrievalNode.Workers.UpsertChunks do
  use Oban.Worker,
    queue: :upsert,
    max_attempts: 5,
    unique: [period: {30, :minutes}, keys: [:pending_chunk_ids],
             states: [:available, :scheduled, :executing]]

  alias RetrievalNode.Repo
  alias RetrievalNode.Ingestion.{PendingChunks, Chunk}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pending_chunk_ids" => ids}}) do
    rows = PendingChunks.fetch_many!(ids)

    entries =
      Enum.map(rows, fn row ->
        %{
          source: row.source,
          natural_key: row.natural_key,
          chunk_index: row.chunk_index,
          content: row.chunk_content,
          content_hash: row.content_hash,
          embedding: row.embedding,
          chunk_quality: row.chunk_quality,
          inserted_at: {:placeholder, :now},
          updated_at: {:placeholder, :now}
        }
      end)

    Ecto.Multi.new()
    |> Ecto.Multi.insert_all(:upsert_chunks, Chunk, entries,
      placeholders: %{now: DateTime.utc_now()},
      on_conflict: {:replace, [:content, :content_hash, :embedding, :chunk_quality, :updated_at]},
      conflict_target: [:source, :natural_key, :chunk_index]
    )
    |> Ecto.Multi.run(:cleanup, fn repo, _ -> {:ok, repo.delete_all(PendingChunks.by_ids(ids))} end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
```

`ON CONFLICT (source, natural_key, chunk_index) DO UPDATE` (via
`on_conflict: {:replace, ...}`) means re-running the same file/issue/doc —
whether from a genuine retry, a duplicate `UpsertChunks` enqueue slipping past
the `unique` guard's race window, or a full re-sync after a watermark reset —
overwrites the existing chunk row in place rather than inserting a duplicate.
`content_hash` is carried along so a future incremental-diff optimization
(skip re-embedding when hash is unchanged) can short-circuit earlier in the
pipeline without changing this upsert's correctness.

## 7. Full worker module sketches

See `ChunkFiles` and `UpsertChunks` above (sections 5-6) for the two workers
with nontrivial control flow. `RepoSync`, `JiraSync`, `DriveSync`, and
`EmbedBatch` follow the same shape (watermark read -> Ecto.Multi bulk insert
of `pending_chunks` + next-stage jobs, or Nx.Serving batch call + write-back +
enqueue) using the same `unique`/`max_attempts` settings tabulated in sections
4-5; they are omitted here for space but should be written using the exact
`Ecto.Multi.insert_all(pending_chunks) |> Oban.insert_all(jobs)` composition
shown in the DAG table, with all job args restricted to IDs/strings per Iron
Laws 2, 4, and 6.

## 8. Webhook path

```
Git provider (GitHub/GitLab push webhook)
  → Phoenix controller, verifies signature
  → Oban.insert(RetrievalNode.Workers.RepoSync.new(
      %{"repo_id" => repo_id},
      unique: [period: {10, :minutes}, keys: [:repo_id],
               states: [:available, :scheduled, :executing]]
    ))
```

The webhook path reuses **the exact same `RepoSync` worker and `unique`
constraint** as the cron fallback (§3, §4) — there is no separate
webhook-triggered worker. This is deliberate: `RepoSync` re-derives "what
changed" from a `git fetch` + diff against the stored watermark at execution
time, not from the webhook payload, so it doesn't matter whether a given
execution was triggered by cron or by a webhook — the result is identical,
and the `unique` constraint transparently collapses whichever trigger arrives
second into a no-op insert.

This is what makes webhook-storm dedup free: a burst of rapid pushes
(force-push storms, a fast sequence of merges, CI retriggers) to the same
repo within the 10-minute `unique` window collapses to a single `RepoSync`
execution — duplicate inserts are rejected outright by the unique index, no
wasted queue slot or job row. Whichever single execution wins the race still
picks up every commit that landed before it actually ran (since it diffs
live `git fetch` output, not a queued list of "what the webhook said
changed"), so coalescing loses no data, only redundant work. The 15-minute
cron poll (§3) exists purely to bound staleness for the case where a webhook
is missed entirely (delivery failure, misconfigured hook, a repo added
before its webhook is wired up) — it is not the primary trigger path.

No new worker, queue, or `unique` policy is needed for the webhook leg beyond
"call `Oban.insert` on the same `RepoSync.new/2` from a Phoenix controller
instead of from `Oban.Plugins.Cron`."
