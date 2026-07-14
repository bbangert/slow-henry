# MCP Tool Layer Design — `retrieval_node` (anubis_mcp v1.6.2)

## Status of source verification

Verified via WebFetch against live hexdocs (`anubis-mcp.hexdocs.pm`, redirected from `hexdocs.pm/anubis_mcp`) and the GitHub repo (`zoedsoupe/anubis-mcp`, formerly `hermes-mcp`) on 2026-07-14:

- Server/tool definition macros (`use Anubis.Server`, `use Anubis.Server.Component, type: :tool`, `schema do ... end`, `execute/2`, `Response` module) — **verified**, current as of v1.6.x docs.
- Streamable HTTP Plug mounting (`Anubis.Server.Transport.StreamableHTTP.Plug`, both as an Endpoint `plug` and as a router `forward`) — **verified**.
- Supervision tree entry (`{MyApp.Server, transport: :streamable_http}`) — **verified** at a high level; exact child-spec options (pool size, session registry name, etc.) were **not** enumerated in the fetched docs.
- Exact error-tuple contract for `execute/2` failures (e.g. `{:error, reason, frame}` vs `{:reply, Response.error(...), frame}`) — **NOT independently verified**. The docs page fetched showed only the success path (`Response.error/2` exists as a helper, confirmed) but did not show a worked failure example or the precise return-tuple shape Anubis expects for a tool-level error vs a protocol-level error. **This is the one flagged risk in this design** — Section 5 below specifies a design against the verified `Response.error/2` helper, which is the safest bet, but confirm the exact tuple shape against the installed dependency source (`mix deps.get && grep -r "def handle_tool_call\|Response.error" deps/anubis_mcp/lib`) before implementation.
- `input_schema` generation from the `schema do end` DSL (field types, `required:`, `description:`) — **verified** via docs example (`field :text, :string, required: true, max_length: 150, description: "..."`).

Everything else in this document is concrete design built on top of those verified primitives.

---

## 1. Registration pattern

### 1.1 Server module

One `Anubis.Server`-based module per MCP server exposed by the app (we only need one):

```elixir
defmodule RetrievalNode.MCP.Server do
  use Anubis.Server,
    name: "retrieval-node",
    version: "0.1.0",
    capabilities: [:tools]

  component RetrievalNode.MCP.Tools.SemanticSearch
  component RetrievalNode.MCP.Tools.Grep
  component RetrievalNode.MCP.Tools.GetFile
  component RetrievalNode.MCP.Tools.ListRepos
end
```

- `capabilities: [:tools]` — we expose tools only (no resources/prompts) for v1.
- Each `component` is a distinct module in `lib/retrieval_node/mcp/tools/`. Anubis registers each `use Anubis.Server.Component, type: :tool` module's schema + `execute/2` under the tool name derived from the module (or an explicit `name:` option on `use Anubis.Server.Component` if the DSL supports overriding it — confirm; default assumption is it derives from module name unless overridden, so name the modules to match the desired external tool name, e.g. `SemanticSearch` module documents itself but the four external tool names required are `semantic_search`, `grep`, `get_file`, `list_repos` — pass an explicit `name: "semantic_search"` option to `use Anubis.Server.Component` if snake_case tool names don't fall out of the module name automatically).

### 1.2 Supervision

Added to `RetrievalNode.Application.start/2`, alongside the rest of the OTP tree (Repo, PubSub, Endpoint, and whatever the Ingest/Search supervisors are):

```elixir
children = [
  RetrievalNode.Repo,
  {Phoenix.PubSub, name: RetrievalNode.PubSub},
  # ... Ingest.Supervisor, Search.Supervisor, etc. (per the parallel OTP design) ...
  {RetrievalNode.MCP.Server, transport: :streamable_http},
  RetrievalNodeWeb.Endpoint
]
```

`transport: :streamable_http` tells the Anubis server GenServer to expect an HTTP-driven transport (as opposed to `:stdio`) — the actual HTTP surface is wired in separately via the Plug in the Endpoint (below). Order matters only in that the MCP server should start before the Endpoint so the Plug has something to dispatch to.

### 1.3 Mounting on the Endpoint

Per the fixed requirement ("mounted as a Plug at `/mcp` on the Phoenix Endpoint"), add the plug directly in `lib/retrieval_node_web/endpoint.ex`, before the `plug RetrievalNodeWeb.Router` line, scoped so it only intercepts `/mcp`:

```elixir
defmodule RetrievalNodeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :retrieval_node

  # ... existing plugs (Plug.Static, Plug.RequestId, etc.) ...

  plug Anubis.Server.Transport.StreamableHTTP.Plug,
    server: RetrievalNode.MCP.Server,
    path: "/mcp"

  plug RetrievalNodeWeb.Router
end
```

This is the verified Endpoint-level mounting form. If auth/plug ordering ever needs the MCP endpoint to sit behind router-level pipelines (e.g. a `:mcp_auth` pipeline) instead of the bare Endpoint, the equivalent router form is:

```elixir
# router.ex — alternative if we need pipeline composition (CORS, auth) around /mcp
forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: RetrievalNode.MCP.Server
```

Default to the Endpoint-level `plug` form per the fixed requirement; switch to the router `forward` only if a future need (e.g. per-tool auth pipeline) demands it.

---

## 2. Tool schemas

All four tools live in `lib/retrieval_node_web/mcp/tools/` (thin, Anubis-facing) and delegate to `RetrievalNode.Tools` (the context) for all logic — see Section 4.

### 2.1 `semantic_search`

```elixir
defmodule RetrievalNode.MCP.Tools.SemanticSearch do
  @moduledoc """
  Hybrid dense+BM25 (RRF-fused) semantic search across indexed code chunks,
  Jira issues, and Drive documents. Returns lightweight back-links and short
  context snippets only — NOT full content. To read full content for a code
  result, call get_file with the returned repo/path/ref.
  """

  use Anubis.Server.Component, type: :tool, name: "semantic_search"

  alias Anubis.Server.Response
  alias RetrievalNode.Tools

  schema do
    field :query, :string, required: true,
      description: "Natural-language or keyword search query."
    field :source, :string, required: false,
      description: "Restrict to one source type: \"code\", \"jira\", or \"drive\". Omit to search all sources."
    field :repo, :string, required: false,
      description: "Restrict code results to this repo slug (e.g. \"org/service-name\"). Ignored for jira/drive results."
    field :lang, :string, required: false,
      description: "Restrict code results to this language (e.g. \"elixir\", \"python\"). Ignored for jira/drive results."
  end

  @impl true
  def execute(params, frame) do
    case Tools.semantic_search(params) do
      {:ok, results} -> {:reply, Response.json(Response.tool(), %{results: results}), frame}
      {:error, reason} -> {:reply, Response.error(Response.tool(), format_error(reason)), frame}
    end
  end

  defp format_error(:invalid_source), do: "source must be one of: code, jira, drive"
  defp format_error(reason), do: "semantic_search failed: #{inspect(reason)}"
end
```

### 2.2 `grep`

```elixir
defmodule RetrievalNode.MCP.Tools.Grep do
  @moduledoc """
  Regex search (ripgrep) over local bare git mirrors of indexed repos.
  Use for exact pattern/symbol lookups; use semantic_search for conceptual
  or natural-language queries.
  """

  use Anubis.Server.Component, type: :tool, name: "grep"

  alias Anubis.Server.Response
  alias RetrievalNode.Tools

  schema do
    field :pattern, :string, required: true,
      description: "Regex pattern to search for (ripgrep syntax)."
    field :repo, :string, required: false,
      description: "Restrict search to this repo slug. Omit to search across all indexed repos."
  end

  @impl true
  def execute(params, frame) do
    case Tools.grep(params) do
      {:ok, matches} -> {:reply, Response.json(Response.tool(), %{matches: matches}), frame}
      {:error, reason} -> {:reply, Response.error(Response.tool(), format_error(reason)), frame}
    end
  end

  defp format_error(:repo_not_found), do: "repo not found or not indexed"
  defp format_error(:invalid_pattern), do: "invalid regex pattern"
  defp format_error(:rg_not_found), do: "ripgrep is not installed on this server"
  defp format_error(reason), do: "grep failed: #{inspect(reason)}"
end
```

### 2.3 `get_file`

```elixir
defmodule RetrievalNode.MCP.Tools.GetFile do
  @moduledoc """
  Fetch the exact contents of a file from a repo's bare git mirror, matching
  what semantic_search and grep results reference. Use this to read full
  content after a search/grep result points you at a file.
  """

  use Anubis.Server.Component, type: :tool, name: "get_file"

  alias Anubis.Server.Response
  alias RetrievalNode.Tools

  schema do
    field :repo, :string, required: true,
      description: "Repo slug, e.g. \"org/service-name\"."
    field :path, :string, required: true,
      description: "File path within the repo, relative to repo root."
    field :ref, :string, required: false,
      description: "Git ref (branch, tag, or commit SHA). Defaults to the repo's default branch (typically main/master)."
  end

  @impl true
  def execute(params, frame) do
    case Tools.get_file(params) do
      {:ok, content} -> {:reply, Response.json(Response.tool(), content), frame}
      {:error, reason} -> {:reply, Response.error(Response.tool(), format_error(reason)), frame}
    end
  end

  defp format_error(:repo_not_found), do: "repo not found or not indexed"
  defp format_error(:file_not_found), do: "file not found at that ref"
  defp format_error(:invalid_ref), do: "ref not found in repo"
  defp format_error(:path_traversal), do: "path escapes repo root"
  defp format_error(reason), do: "get_file failed: #{inspect(reason)}"
end
```

### 2.4 `list_repos`

```elixir
defmodule RetrievalNode.MCP.Tools.ListRepos do
  @moduledoc """
  List all indexed sources/repos available to semantic_search, grep, and
  get_file. Call this first if you're unsure what repo slugs exist.
  """

  use Anubis.Server.Component, type: :tool, name: "list_repos"

  alias Anubis.Server.Response
  alias RetrievalNode.Tools

  # No input fields — Anubis should emit an empty object schema `{}`.
  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:ok, repos} = Tools.list_repos()
    {:reply, Response.json(Response.tool(), %{repos: repos}), frame}
  end
end
```

`list_repos` has no failure mode worth surfacing to the model (it's a pure read of the `Ingest` registry/table), so no `{:error, ...}` branch — but if `Tools.list_repos/0` can fail (DB down), still pattern-match both branches instead of `{:ok, repos} = ...` in production code; shown simplified here as the base case.

---

## 3. Response shape contract

### 3.1 `semantic_search` — token-efficient shape

Each result is metadata + back-link + short breadcrumb, never full chunk content:

```json
{
  "results": [
    {
      "source_type": "code",
      "repo": "org/service-name",
      "path": "lib/service_name/billing.ex",
      "ref": "main",
      "breadcrumb": "def charge_customer(customer, amount) do ... handles Stripe idempotency key generation",
      "score": 0.83
    },
    {
      "source_type": "jira",
      "key": "PROJ-1234",
      "breadcrumb": "Billing: idempotency key collisions on retried charges — root cause found in charge_customer/2",
      "score": 0.79
    },
    {
      "source_type": "drive",
      "url": "https://docs.google.com/document/d/abc123/edit",
      "title": "Billing Retry Design Doc",
      "breadcrumb": "Section 3: Idempotency keys must be deterministic per (customer, invoice) pair",
      "score": 0.71
    }
  ]
}
```

Field rules per `source_type`:

| `source_type` | Back-link fields | Content field |
|---|---|---|
| `code` | `repo`, `path`, `ref` | `breadcrumb` (≤ ~200 chars: surrounding function signature / comment / a short quoted fragment — never the full chunk) |
| `jira` | `key` (e.g. `PROJ-1234`) | `breadcrumb` (issue summary / matched comment excerpt) |
| `drive` | `url`, `title` | `breadcrumb` (matched paragraph excerpt, truncated) |

`score` is the fused RRF score (float, descending sort — Search context guarantees ordering, tool layer doesn't re-sort). No `content`, `full_text`, or `chunk` field is ever present — that's the entire point of the token-efficiency requirement. If a caller wants the actual code, they call `get_file(repo, path, ref)` with the exact `repo`/`path`/`ref` triple from the result, guaranteeing the fetched content matches what was indexed (same bare mirror).

### 3.2 `grep` — shape

```json
{
  "matches": [
    {
      "repo": "org/service-name",
      "path": "lib/service_name/billing.ex",
      "line": 42,
      "text": "  def charge_customer(customer, amount) do"
    }
  ]
}
```

One entry per matching line (ripgrep `--line-number` semantics). No full-file content; `text` is just the matched line (ripgrep default, not `-C` context — keep it minimal; the caller escalates to `get_file` for surrounding context). `repo` is included per match since a repo-omitted grep spans multiple repos.

### 3.3 `get_file` — full-content shape

```json
{
  "repo": "org/service-name",
  "path": "lib/service_name/billing.ex",
  "ref": "main",
  "content": "defmodule ServiceName.Billing do\n  ...\nend\n"
}
```

This is the one tool that returns full content by design — it's the deliberate "pay for what you read" step after `semantic_search`/`grep` narrow down the target. `ref` in the response echoes the resolved ref (if the caller omitted `ref` and the default branch was used, echo the actual branch name resolved, not `nil`, so the caller can pin a follow-up `get_file` call to the exact same commit if needed — resolve to a commit SHA via `git rev-parse` if we want reproducibility across concurrent pushes; simplest v1: echo whatever ref string was used, branch name or SHA).

### 3.4 `list_repos` — shape

```json
{
  "repos": [
    {"repo": "org/service-name", "source_type": "code", "default_ref": "main"},
    {"repo": "PROJ", "source_type": "jira"},
    {"repo": "team-drive", "source_type": "drive"}
  ]
}
```

`repo` is the slug usable as the `repo` param on `semantic_search`/`grep`/`get_file` (only meaningful for `source_type: "code"` — jira/drive entries are informational, listing what's indexed, since jira/drive aren't addressed by `repo` in the other three tools).

---

## 4. Where the shell-outs live — `GitMirror` facade

Per the "wrap third-party APIs" convention, all `System.cmd` calls for `rg` and `git` live in one facade module, never called directly from the `Tools` MCP-facing modules or from `Search`/`Ingest` business logic.

```
lib/retrieval_node/ingest/git_mirror.ex   # facade — all System.cmd here
lib/retrieval_node/ingest.ex              # context — list_repos, mirror bookkeeping
lib/retrieval_node/search.ex              # context — semantic_search (RRF over dense+BM25)
lib/retrieval_node/tools.ex               # context — thin orchestration for the 4 MCP tools
lib/retrieval_node_web/mcp/server.ex
lib/retrieval_node_web/mcp/tools/*.ex     # Anubis components — call Tools.*, nothing else
```

### 4.1 `RetrievalNode.Ingest.GitMirror`

```elixir
defmodule RetrievalNode.Ingest.GitMirror do
  @moduledoc """
  Facade over `rg` and `git` shell-outs against local bare mirrors.
  All System.cmd/3 calls for repo inspection live here — nowhere else.
  """

  @mirrors_root Application.compile_env(:retrieval_node, [__MODULE__, :mirrors_root], "/var/lib/retrieval_node/mirrors")

  @doc "ripgrep search over one repo's bare mirror, or all mirrors if repo is nil."
  @spec grep(pattern :: String.t(), repo :: String.t() | nil) ::
          {:ok, [%{repo: String.t(), path: String.t(), line: pos_integer(), text: String.t()}]}
          | {:error, :repo_not_found | :invalid_pattern | :rg_not_found | {:rg_error, String.t()}}
  def grep(pattern, repo)

  @doc "Exact file contents at `ref` from a repo's bare mirror, via `git show ref:path`."
  @spec show(repo :: String.t(), path :: String.t(), ref :: String.t()) ::
          {:ok, String.t()}
          | {:error, :repo_not_found | :file_not_found | :invalid_ref | :path_traversal}
  def show(repo, path, ref)

  @doc "Resolve a repo slug to its bare-mirror path, or nil if not indexed."
  @spec mirror_path(repo :: String.t()) :: String.t() | nil
  def mirror_path(repo)
end
```

**`grep/2` implementation notes:**

- Build the argument list, never a shell string: `System.cmd("rg", ["--line-number", "--no-heading", "--color", "never", "-e", pattern, mirror_dir], stderr_to_stdout: true)`. Passing `pattern` and `mirror_dir` as separate list elements means no shell interpolation — ripgrep receives them as literal argv entries, so no `;`, `` ` ``, `$()`, or `|` in the pattern can break out of the intended argument, regardless of pattern content.
- `repo: nil` → iterate all mirrors under `@mirrors_root` (from `Ingest` repo registry, not a directory listing, to avoid indexing anything not actually registered) and merge results, tagging each match with its `repo`.
- Detect "ripgrep not installed" via `System.find_executable("rg")` returning `nil` up front (return `{:error, :rg_not_found}` before ever calling `System.cmd`, rather than letting `System.cmd` raise `ErlangError`/`:enoent`).
- Bare git mirrors don't have a working tree, but `rg` needs real files to scan — either (a) maintain a shallow checked-out working copy alongside the bare mirror specifically for grep, updated on each ingest pull, or (b) run `git --git-dir=<mirror> archive <ref> | rg` piped via a temp extraction. Recommend (a): keep a read-only checkout dir per repo (`<mirror>.worktree/`) refreshed by `Ingest` on each sync, since (b) requires re-extracting on every grep call and ties `grep`'s "which ref" question to an argument this tool signature doesn't even take (per the fixed spec, `grep(pattern, repo?)` has no `ref` — it searches the currently-synced tree). Document this clearly: `grep` searches the latest synced snapshot, not an arbitrary ref; `get_file` is ref-aware, `grep` is not (matches the fixed tool signatures given).
- `invalid_pattern` — ripgrep exits nonzero with a regex-parse error message on stderr for a malformed pattern; parse `rg`'s exit status: `0` = matches found, `1` = no matches (not an error — return `{:ok, []}`), `2` = actual error (regex syntax, I/O) — return `{:error, {:rg_error, stderr_output}}`, which the tool module's `format_error/1` renders as "invalid regex pattern" only when the stderr text matches a regex-error pattern, otherwise the generic message.

**`show/3` implementation notes:**

- `System.cmd("git", ["--git-dir", mirror_dir, "show", "#{ref}:#{path}"], stderr_to_stdout: true)` — again, argument-list form; `ref` and `path` are never concatenated into a shell string, they're concatenated into one *argv element* (`"#{ref}:#{path}"`) which `git show` parses internally — this is safe from shell injection (no shell is invoked, `System.cmd` uses `execvp` directly) but `path` must still be validated against traversal before this call (see below), since `git show ref:../../etc/passwd` is syntactically valid to git even though no shell is involved.
- Path traversal guard: reject any `path` containing `..` path segments, a leading `/`, or that `Path.safe_relative/1`-fails, **before** constructing the `git show` argument. `Path.safe_relative(path)` (stdlib, no manual parsing) is the right primitive — reject if it returns `:error`. This guards against a malicious/confused model passing `path: "../../../etc/passwd"` — even though `git show` is scoped to the repo's object database (it can't literally read `/etc/passwd`), it *can* walk the tree structure in ways that don't correspond to the caller's intended file if you don't validate, and defense-in-depth here is cheap and expected practice regardless of git's actual blast radius.
- `repo_not_found` — resolved via `mirror_path/1` returning `nil` before ever shelling out.
- `file_not_found` vs `invalid_ref` — `git show` exits nonzero for both "no such ref" and "no such path at that ref" with different stderr text (`fatal: invalid object name '<ref>'` vs `fatal: path '<path>' does not exist in '<ref>'`); pattern-match stderr to distinguish, falling back to a generic error if the message shape doesn't match either known pattern.

**`mirror_path/1`:** looks up the repo slug against `Ingest`'s registered-repos table (not a raw directory scan) and returns the absolute mirror path if registered and present on disk, else `nil`. This is the single source of truth both `grep/2` and `show/3` use to translate `repo` slugs into filesystem paths — keeps repo-slug validation in one place.

### 4.2 `RetrievalNode.Tools` (context, called by the Anubis components)

```elixir
defmodule RetrievalNode.Tools do
  @moduledoc """
  Public interface for the four MCP tools. Thin — delegates to Search,
  Ingest, and Ingest.GitMirror. No Repo/System.cmd calls in this module
  directly; those live in the delegated contexts/facade.
  """

  alias RetrievalNode.{Search, Ingest}
  alias RetrievalNode.Ingest.GitMirror

  @spec semantic_search(map()) :: {:ok, [map()]} | {:error, term()}
  def semantic_search(%{query: query} = params) do
    with {:ok, source} <- validate_source(params[:source]) do
      Search.hybrid_search(query, source: source, repo: params[:repo], lang: params[:lang])
    end
  end

  @spec grep(map()) :: {:ok, [map()]} | {:error, term()}
  def grep(%{pattern: pattern} = params), do: GitMirror.grep(pattern, params[:repo])

  @spec get_file(map()) :: {:ok, map()} | {:error, term()}
  def get_file(%{repo: repo, path: path} = params) do
    ref = params[:ref] || Ingest.default_ref(repo)

    with {:ok, content} <- GitMirror.show(repo, path, ref) do
      {:ok, %{repo: repo, path: path, ref: ref, content: content}}
    end
  end

  @spec list_repos() :: {:ok, [map()]} | {:error, term()}
  def list_repos, do: Ingest.list_repos()

  defp validate_source(nil), do: {:ok, nil}
  defp validate_source(s) when s in ["code", "jira", "drive"], do: {:ok, s}
  defp validate_source(_), do: {:error, :invalid_source}
end
```

This keeps every Anubis tool component a 2–4 line pass-through: parse the Anubis-supplied param map (already validated against the `schema do end` types/`required:` flags by Anubis before `execute/2` is even called), call one `Tools.*` function, translate `{:ok, _} | {:error, _}` into `{:reply, Response.json/error(...), frame}`.

---

## 5. Error handling contract

### 5.1 What's verified vs designed

Anubis's `schema do end` DSL performs input validation (types, `required:`) **before** `execute/2` runs — confirmed by docs showing declarative field constraints (`required: true`, `max_length: 150`) as part of the macro, which is the standard MCP-server-framework pattern (reject malformed input at the protocol layer, only call the handler with a validated map). This means "grep pattern invalid" is **not** a schema-validation error (any string is a syntactically valid `pattern:` input) — it's a domain error surfaced by ripgrep at runtime, handled inside `execute/2` via the `{:error, reason}` branch, not by Anubis's input validation.

What is **not verified**: the exact tuple Anubis expects when `execute/2` wants to signal a **tool-level failure** (as opposed to a **protocol-level** malformed-request failure, which Anubis handles itself pre-`execute/2`). The `Response.error/2` helper is confirmed to exist. The design below commits to `{:reply, Response.error(Response.tool(), message), frame}` as the tool-failure return — this renders as a normal MCP tool result with `isError: true` and the message as content (matching the MCP spec's `isError` convention, which every MCP server SDK implements the same way regardless of language). **Confirm this exact tuple/behavior against `deps/anubis_mcp` source before merging** — if wrong, the compiler/dialyzer will catch a bad return type immediately since `execute/2` has a declared behaviour callback.

### 5.2 Per-condition mapping

| Condition | Where detected | Tool-facing message (via `Response.error/2`) |
|---|---|---|
| Repo not found / not indexed | `GitMirror.mirror_path/1` returns `nil` | `"repo not found or not indexed"` |
| ripgrep not installed | `System.find_executable("rg")` is `nil`, checked in `GitMirror.grep/2` before shelling out | `"ripgrep is not installed on this server"` |
| grep pattern invalid | `rg` exit code `2` with regex-parse stderr | `"invalid regex pattern"` |
| grep no matches | `rg` exit code `1` | **not an error** — `{:ok, []}`, tool returns `{"matches": []}` |
| File not found at ref | `git show` stderr `path ... does not exist in` | `"file not found at that ref"` |
| Ref not found | `git show` stderr `invalid object name` | `"ref not found in repo"` |
| Path traversal attempt | `Path.safe_relative/1` rejects `path` pre-shell-out | `"path escapes repo root"` |
| `source` not one of code/jira/drive | `Tools.validate_source/1` | `"source must be one of: code, jira, drive"` |
| Search backend (Meilisearch/pgvector/etc.) unavailable | bubbled up from `Search.hybrid_search/2` as `{:error, :search_unavailable}` | `"search backend unavailable, try again shortly"` |
| Any other/unexpected error | catch-all `{:error, reason}` clause | `"<tool> failed: #{inspect(reason)}"` — logged at `:error` with full reason server-side; message to the model stays generic to avoid leaking internals |

All four tool components follow the same shape: a `case` on the `Tools.*` result with one `{:ok, _}` success branch and a `format_error/1` private function mapping known atoms to human-readable strings for the model, with a catch-all for anything unmapped (so a new failure mode added to `GitMirror` or `Search` later doesn't crash the tool — worst case it surfaces `inspect(reason)`, not a raw exception).

**Never let an exception escape `execute/2` uncaught.** Wrap the `Tools.*` call bodies in each facade/context function to convert exceptions from `System.cmd` (e.g. `ErlangError` on `:enoent` if `git` itself is missing, not just `rg`) into `{:error, reason}` tuples at the `GitMirror` boundary, so `execute/2` never has to `rescue` — that keeps the "narrow bare rescue" convention intact (rescue only at the shell-out boundary, in the facade, where you know exactly what can fail and why).
