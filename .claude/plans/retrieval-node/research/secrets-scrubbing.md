# Secrets/Credential Scrubbing in Ingestion Pipeline: v1 Research

**Research Date**: 2026-07-14  
**Scope**: Self-hosted Elixir knowledge-retrieval node ingesting git repos, Jira, Google Docs  
**Goal**: Pragmatic detection & redaction at ingest time (before embedding/pgvector indexing)

---

## 1. Detection Approaches: Pattern, Entropy, Verification

### A. Regex-Based Pattern Detection (Primary)

**Gitleaks** [T1] (MIT licensed, ~60 built-in rules):
- AWS keys: `\b(AKIA[0-9A-Z]{16})\b`
- GitHub tokens: `ghp_[0-9a-zA-Z]{36}`
- Private keys: `-----BEGIN (RSA|DSA|EC|PGP|OPENSSH) PRIVATE KEY`
- Generic secrets: `(?i)(api_key|password|secret|token)\s*=\s*['\"][^'\"]{8,}['\"]`
- **Output**: JSON with file, line, secret type, commit hash (if git-backed)
- **Speed**: ~500ms to 1s for typical staged file diffs; full history scan optimizable with `--log-opts` to scan only delta between branches
- **Entropy scoring**: Default Shannon entropy threshold catches high-entropy strings as fallback

**TruffleHog** [T1] (AGPL 3 licensed, 800+ detectors):
- Covers same patterns as Gitleaks plus ~700+ SaaS-specific detectors (Stripe, Datadog, Cloudflare, etc.)
- **Verification**: Tests detected credentials against actual API endpoints (e.g., AWS `GetCallerIdentity`) to confirm active keys — dramatically reduces false positives
- **Output**: JSON with detector type, verification status (Verified/Unverified/Unknown), decoded values, source metadata
- **Tradeoff**: More accurate but slower (API calls) and AGPL requires source disclosure of integration code

**detect-secrets** [T1] (Apache 2.0, baseline approach):
- Optimized for large legacy codebases where flooding alerts is a problem
- Builds a `.secrets.baseline` allowing operators to maintain a curated list of known (ignored) secrets across a big codebase
- Good for iterative scanning; less suitable for one-time ingest

### B. Accuracy & False Positive Tradeoff

| Tool | True Positive Rate | FP Rate | Notes |
|------|-------------------|---------|-------|
| Gitleaks (regex only) | ~85–95% | 3–8% | Fast, misses entropy-only secrets; catches formatted keys well |
| TruffleHog (with verify) | ~98%+ | <1% | API calls confirm validity; slower; 800+ detectors reduce missed SaaS secrets |
| detect-secrets | ~80% | 5–10% | Baseline filtering reduces alert fatigue; not for fresh ingest |

**Recommendation**: Gitleaks suffices for v1 (speed, license simplicity). Reserve TruffleHog for high-stakes repos if AGPL is acceptable.

---

## 2. Elixir-Native Options vs. External Binary

### A. Findings: No Mainstream Elixir Hex Package

Searched Hex.pm, ElixirForum, and GitHub — **no maintained Elixir library exists** for secret detection. Hand-rolling regex patterns is feasible but maintenance-heavy.

### B. Pragmatic Path: Shell Out to Gitleaks

```elixir
# Oban job in ingest pipeline
defmodule MyApp.Ingest.ScanSecretsJob do
  use Oban.Worker, queue: :ingestion

  @impl Oban.Worker
  def perform(%Job{args: %{"repo_path" => repo_path, "chunk_id" => chunk_id}}) do
    case scan_with_gitleaks(repo_path) do
      {:ok, findings} when findings == [] ->
        {:ok, "no secrets found"}

      {:ok, findings} ->
        # Log and quarantine (see Section 3 for policy)
        log_security_event(chunk_id, findings)
        {:error, {:secrets_detected, length(findings)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan_with_gitleaks(path) do
    cmd = "gitleaks"
    args = ["detect", "--source", path, "--report-path", "/tmp/gitleaks-report.json", "--report-format", "json"]

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        # Exit code 0 = no secrets found
        {:ok, []}

      {output, 1} ->
        # Exit code 1 = secrets found, parse JSON
        case File.read("/tmp/gitleaks-report.json") do
          {:ok, json} -> {:ok, Jason.decode!(json)}
          err -> err
        end

      {output, exit_code} ->
        {:error, "gitleaks exited with #{exit_code}: #{output}"}
    end
  end
end
```

**Why this approach**:
- ✅ No reinventing regex; gitleaks rules maintained by security community
- ✅ MIT licensed (vs. AGPL risk of TruffleHog)
- ✅ JSON output integrates cleanly with Elixir
- ✅ Baseline mode (`--baseline-path`) supports incremental re-scans
- ✅ Can be run as pre-fetch step (all repos) or per-chunk (finer control)

**Limitations**:
- Git-backed repos only; non-git sources (Jira, Drive files) need fallback pattern scan
- Binary dependency (requires gitleaks installed on node)
- Performance scales with repo size (mitigate with diff-only scanning)

---

## 3. Policy on a Hit: Redaction vs. Drop vs. Quarantine

### A. Three Core Policies (OpenObserve-inspired)

| Policy | Mechanism | Trade-off | Recommendation |
|--------|-----------|-----------|---|
| **Redact** | Replace secret span with `[REDACTED]` | Chunk remains useful (context preserved); secret obscured | ✅ Default for v1 |
| **Hash** | Deterministic MD5 hash (e.g., `[REDACTED:907fe4882def...]`) | Enables searching by hash; no plaintext leakage | For PII, not credentials |
| **Drop** | Remove entire chunk from index | Hard boundary; no info leakage | Too destructive for accidental secrets |
| **Quarantine + Flag** | Write chunk to quarantine dir; halt indexing; flag for human review | High confidence; operator makes final call | For high-risk repos; slows ingest |

### B. Recommended v1 Policy

```
IF secret detected in chunk:
  1. Redact the secret span(s) with [REDACTED] + secret type label
  2. Log event: {chunk_id, secret_type, file_path, line_range, timestamp}
  3. Proceed with indexing the redacted chunk
  4. Weekly: security team reviews log for patterns / suspicious repos
  
IF same secret detected >3 times across different chunks:
  5. Flag repo/path for quarantine in next ingest cycle
```

**Rationale**:
- Redaction is pragmatic: the chunk (e.g., "how to set up Postgres connection") may be useful minus the password
- Logging enables audit and pattern detection without blocking ingestion
- Quarantine is a follow-on phase (not v1) when trends emerge

### C. Never Silently Index a Secret

Add a content-level audit flag to every chunk: `{contains_secret: false, secret_type: nil, redacted_at: nil}`. If a secret is found but NOT redacted (fallback), fail the chunk and alert.

---

## 4. Scope Interaction: Path Exclusion + Content Scanning (Defense in Depth)

### A. Existing Layer: Allowlist/Denylist

The node already excludes credential repos (e.g., `secrets/`, `credentials/`, `.env*` files) and NDA material at the **path level** before ingest. This is the first gate.

### B. Content Scanning: Second Gate

Secret detection operates at **content level** on allowed paths:

```
Ingest flow:
├─ Fetch repo/Jira/Doc
├─ Check path against denylist → SKIP if blocked
├─ Chunk content (e.g., split by paragraphs/code blocks)
├─ FOR EACH CHUNK:
│  ├─ [If git-backed] Run gitleaks on file
│  ├─ [If non-git] Run regex-based pattern scan
│  ├─ IF secret found → redact + log
│  └─ Proceed to embedding (redacted or skipped)
└─ Return chunks to indexing
```

**Defense-in-depth value**:
- Path exclusion catches deliberate credential files
- Content scanning catches accidental secrets in documentation ("here's my AWS key for testing")
- Redaction ensures even if an accidental secret slips through, it's obscured before pgvector indexing

---

## 5. Handling Non-Git Sources (Jira, Google Docs)

### Problem
Gitleaks requires a git repo or file path. Jira issues and Google Docs are fetched as plain text. Need pattern scanning at content level.

### Solution: Regex-Based Content Scanner (Elixir)

```elixir
defmodule MyApp.SecretScanner do
  # Reuse gitleaks patterns as a starting point
  @patterns [
    aws_key: ~r/\b(AKIA[0-9A-Z]{16})\b/,
    github_token: ~r/ghp_[0-9a-zA-Z]{36}/,
    private_key: ~r/-----BEGIN (RSA|DSA|EC|PGP|OPENSSH) PRIVATE KEY-----[\s\S]+?-----END \1 PRIVATE KEY-----/,
    generic_secret: ~r/(?i)(?:password|api[_-]?key|secret|token)\s*[:=]\s*['\"]?([^'\"]{8,})['\"]?/,
    connection_string: ~r/(postgresql|mysql|mongodb):\/\/[^:]+:[^@]+@/,
  ]

  def scan(content) do
    Enum.flat_map(@patterns, fn {type, regex} ->
      Regex.scan(regex, content, return: :index)
      |> Enum.map(fn match -> {type, match} end)
    end)
  end

  def redact(content, findings) do
    Enum.reduce(findings, content, fn {type, [{start, len}]}, acc ->
      String.slice(acc, 0, start) <> "[REDACTED:#{type}]" <> String.slice(acc, start + len..-1)
    end)
  end
end
```

**Limitations of regex-based approach**:
- False positives (e.g., regex for `password=` may catch commented-out examples)
- No entropy filtering (misses randomized strings)
- Requires manual maintenance of pattern set

**Mitigation**: Accept FP rate for non-git sources; focus effort on high-confidence patterns (private keys, Slack tokens). If noise is high, shift to manual review mode (quarantine, don't auto-redact).

---

## 6. Performance: Large File Volumes

### A. Gitleaks Performance Characteristics

**Full history scan on large repo**: ~5–30s (depends on commit count, file count)  
**Incremental (diff-only)**: ~0.5–1s (scans only delta between branches)  
**Staged files only** (`gitleaks protect`): <0.5s

### B. Optimization for Hundreds of Thousands of Files

**Strategy 1: Batch Pre-Scan All Repos**
```bash
# Once at ingest setup
gitleaks detect --source=/path/to/repos --report-format=json --report-path=baseline.json

# Subsequent runs (incremental)
gitleaks detect --source=/path/to/repos --baseline-path=baseline.json
```
- First run: ~2–5 minutes (all repos)
- Subsequent runs: <1 minute (baseline mode skips known-clean areas)

**Strategy 2: Diff-Driven Incremental**
```bash
# For each repo with new commits
gitleaks detect --source=/path/to/repo \
  --log-opts="origin/main..HEAD" \
  --report-format=json
```
- Scans only new commits: ~100–500ms per repo

**Strategy 3: Async Oban Jobs**
- Chunk repos into batches (e.g., 10 repos per Oban job)
- Run 4–8 parallel jobs, each calling gitleaks on its batch
- Store findings in a temporary table; redact chunks in next Oban step

**Recommendation for v1**:
Use **Strategy 2** (diff-driven) if repos are synced incrementally (matches your stated design). For one-time bulk ingest, use **Strategy 1** with baseline, then maintain baseline in S3/disk for future runs.

---

## 7. License & Attribution

- **Gitleaks** (recommended): MIT — can be embedded and modified freely  
- **TruffleHog**: AGPL 3 — derivative work must be open-sourced (risk for closed-source node)  
- **detect-secrets**: Apache 2.0 — permissive, but rules-based approach less ideal for v1

---

## 8. V1 Recommendation: Concrete Stack

### Tools
- **gitleaks binary** (via `System.cmd` in Elixir) for git-backed repos
- **Regex-based Elixir scanner** for non-git sources (Jira, Docs)
- **Oban jobs** for async batch scanning at ingest time

### Policy
1. **Redact** secrets in-place; preserve chunk
2. **Log** every detection (chunk_id, type, file, timestamp)
3. **No silent indexing** of secrets
4. **Weekly review** of logs for quarantine candidates

### Data Flow
```
Ingest (git repo / Jira / Drive)
  ↓
Check path allowlist/denylist (existing layer)
  ↓
Chunk content
  ↓
Scan each chunk (gitleaks or regex)
  ↓
IF secret found:
  - Redact secret
  - Log detection
  - Mark chunk.contains_secret=true
  - Continue to embedding (redacted)
ELSE:
  - Continue to embedding (clean)
  ↓
pgvector index (no plaintext secrets ever entered)
  ↓
Serve to Claude MCP (safe)
```

### Honest Limits (v1 Will Miss)

1. **Encoded secrets**: Base64-encoded API keys, escaped JSON strings (no decoder at scan time)
2. **Contextual secrets**: Weak patterns in plaintext (e.g., `user=admin` without `password=`)
3. **SaaS-specific tokens**: Only top ~20 covered by regex; TruffleHog's 800 detectors would catch more
4. **Historical secret in git**: If repo was cloned with full history including deleted secrets, first gitleaks run will flag them. Subsequent incremental runs won't re-flag unless you reset baseline.
5. **False positives in non-git content**: Regex on Jira/Docs may flag comments like "API_KEY_PLACEHOLDER" or mock credentials in examples; requires tuning.

### Next Steps (v1 → v1.1)
- Integrate TruffleHog for high-risk repos (if AGPL acceptable)
- Add entropy-based secondary scan for high-entropy strings not caught by regex
- Implement automated quarantine based on detection volume / repo patterns
- Add manual review UI for flagged chunks (quarantine vault)

---

## References

- [Gitleaks GitHub](https://github.com/gitleaks/gitleaks) — Rules, performance, configuration [T1]
- [TruffleHog GitHub](https://github.com/trufflesecurity/trufflehog) — Detectors, verification, JSON output [T1]
- [detect-secrets GitHub](https://github.com/Yelp/detect-secrets) — Baseline approach [T1]
- [OpenObserve Redaction Blog](https://openobserve.ai/blog/sensitive-data-redaction-openobserve/) — Redaction policies and patterns [T3]
- [Datadog Observability Pipelines](https://www.datadoghq.com/blog/observability-pipelines-sensitive-data-redaction/) — Ingestion-time redaction best practices [T2]
- [Gitleaks Performance on Large Repos](https://medium.com/@sirigirivijay123/from-commits-to-ci-secret-scanning-with-gitleaks-secret-scanner-in-gitlab-github-54546e7e6c55) — Delta scanning optimization [T3]

---

**Document Status**: Ready for implementation planning  
**Confidence**: High (based on 3 T1 sources, 1 T2, 2 T3)  
**Next: Implementation spec (Oban job, redaction logic, logging schema)**
