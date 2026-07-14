defmodule RetrievalNode.Ingest.Scrubber do
  @moduledoc """
  Secret detection + redaction, run as an in-process pre-step before content is
  chunked/embedded. **Fail-closed**: content is never embedded before it has
  passed at least the regex scanner (pure Elixir, no external dependency, cannot
  legitimately fail).

  Policy (`design-oban.md` §5.1):

    * **git** content → `gitleaks`. Exit 0 = clean; exit 1 = **secrets found**,
      which is *normal operation* — redact each finding in place (`[REDACTED:type]`),
      record an audit row, and PROCEED (a redacted chunk is still useful). Any other
      exit, or a missing/broken binary, is the *only* failure case: degrade to the
      regex scanner (a weaker but real scan) and emit a loud telemetry signal —
      never silently skip scanning.
    * **jira/drive** text → the regex scanner directly.

  A high-confidence secret that survives redaction is discarded (`{:cancel, ...}`)
  rather than indexed — the "never index a plaintext secret" guarantee, enforced
  detector-agnostically via `redaction_left_secret?/2`. Audit rows store only a
  `sha256` of the match, never the raw secret. Secrets are also kept out of logs
  and telemetry: only exit codes / exception types are logged, never content or a
  tool's captured output.
  """

  require Logger

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.SecretFinding

  @typedoc "A detected secret span: byte offset + length into the scanned content."
  @type finding :: %{
          detector: :gitleaks | :regex_scanner,
          rule_id: String.t(),
          secret_type: String.t(),
          start: non_neg_integer(),
          length: pos_integer(),
          match: String.t()
        }

  @type result :: %{
          redacted_content: String.t(),
          findings: [finding],
          scrub_mode: String.t(),
          secrets_status: :clean | :redacted
        }

  # Defensive upper bound on scan input. Exceeding it discards the content
  # (`{:cancel, ...}` = fail-closed, not indexed) rather than risk pathological
  # regex runtime. Upstream (2MB chunker cap, source clients) normally bounds this.
  @max_scan_bytes 5_000_000

  # gitleaks-seeded, high-confidence patterns. {secret_type, rule_id, regex}.
  # Ordered high-confidence first; `generic_secret` is the noisy catch-all.
  @patterns [
    {"aws_access_key_id", "aws-access-key", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"gcp_api_key", "gcp-api-key", ~r/\bAIza[0-9A-Za-z\-_]{35}\b/},
    {"github_token", "github-pat", ~r/\bgh[pousr]_[0-9A-Za-z]{36,}\b/},
    {"slack_token", "slack-token", ~r/\bxox[baprs]-[0-9A-Za-z-]{10,}\b/},
    {"jwt", "jwt", ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/},
    {"private_key", "private-key",
     ~r/-----BEGIN (RSA|DSA|EC|PGP|OPENSSH) PRIVATE KEY-----[\s\S]+?-----END \1 PRIVATE KEY-----/},
    {"connection_string", "connection-string",
     ~r{(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s:@/]+:[^\s@/]+@}},
    {"generic_secret", "generic-secret",
     ~r/(?i)(?:password|passwd|api[_-]?key|secret|token)\s*[:=]\s*["']?([^\s"']{8,})["']?/}
  ]

  # Regex secret_types that must not survive redaction. The generic catch-all is
  # excluded (too noisy to hard-fail on). gitleaks findings are always treated as
  # high-confidence (they come from a real scanner).
  @high_confidence_types ~w(aws_access_key_id gcp_api_key github_token slack_token jwt private_key connection_string)

  @doc """
  Scrub `content` for the given `source_type`. Returns `{:ok, result}` (possibly
  with `secrets_status: :redacted`), `{:cancel, reason}` if a high-confidence
  secret survives redaction or the content is too large, or `{:error, reason}` if
  no scan could run at all.
  """
  @spec scrub(String.t(), atom()) :: {:ok, result} | {:cancel, atom()} | {:error, atom()}
  def scrub(content, _source_type)
      when is_binary(content) and byte_size(content) > @max_scan_bytes do
    {:cancel, :content_too_large}
  end

  def scrub(content, :git_repo) when is_binary(content) do
    case gitleaks_scan(content) do
      {:ok, findings} ->
        finish(content, findings, "gitleaks")

      {:error, reason} ->
        # Log only the reason tag/exit code — never content or captured tool output.
        Logger.warning("gitleaks unavailable (#{inspect(reason)}); degrading to regex scan")
        :telemetry.execute([:retrieval_node, :scrub, :degraded], %{count: 1}, %{reason: reason})
        regex_scrub(content, "gitleaks_degraded_regex")
    end
  end

  def scrub(content, source_type)
      when is_binary(content) and source_type in [:jira_project, :drive_folder] do
    regex_scrub(content, "regex")
  end

  defp regex_scrub(content, scrub_mode) do
    finish(content, regex_scan(content), scrub_mode)
  rescue
    # The regex scanner is pure Elixir and should never raise; if it does, NOTHING
    # scanned this content — the true fail-closed terminal state. Log the exception
    # TYPE + stacktrace only (never the message, which could embed the content).
    e ->
      Logger.error(
        "regex scrub raised #{inspect(e.__struct__)}:\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, :scrub_unavailable}
  end

  # Common tail: redact, then fail-closed verify that no high-confidence secret
  # survived, then build the result.
  defp finish(content, findings, scrub_mode) do
    redacted = redact(content, findings)

    if redaction_left_secret?(findings, redacted) do
      {:cancel, :unredactable_secret}
    else
      {:ok,
       %{
         redacted_content: redacted,
         findings: findings,
         scrub_mode: scrub_mode,
         secrets_status: if(findings == [], do: :clean, else: :redacted)
       }}
    end
  end

  @doc "Scan `content` with the built-in regex patterns. Pure; no external deps."
  @spec regex_scan(String.t()) :: [finding]
  def regex_scan(content) when is_binary(content) do
    Enum.flat_map(@patterns, fn {type, rule_id, regex} ->
      regex
      # return: :index gives BYTE offsets; the first element is always the whole
      # match {start, len} (captures follow) — redact the whole match, not a capture.
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [{start, length} | _captures] ->
        %{
          detector: :regex_scanner,
          rule_id: rule_id,
          secret_type: type,
          start: start,
          length: length,
          match: binary_part(content, start, length)
        }
      end)
    end)
  end

  @doc """
  Replace every finding's span with `[REDACTED:type]`. Byte-correct (findings hold
  BYTE offsets, matching `Regex.scan(return: :index)`) and overlap-safe: spans are
  merged and applied in a single left-to-right reconstruction so offsets never drift.
  """
  @spec redact(String.t(), [finding]) :: String.t()
  def redact(content, []), do: content

  def redact(content, findings) do
    spans =
      findings
      |> Enum.map(&{&1.start, &1.start + &1.length, &1.secret_type})
      |> merge_spans()

    # Walk the merged spans left-to-right, accumulating [prefix, marker] iodata in
    # REVERSE (prepend is O(1)); reverse once at the end and flatten to a binary.
    {chunks, pos} =
      Enum.reduce(spans, {[], 0}, fn {s, e, type}, {acc, pos} ->
        prefix = binary_part(content, pos, s - pos)
        {[["[REDACTED:", type, "]"], prefix | acc], e}
      end)

    tail = binary_part(content, pos, byte_size(content) - pos)
    IO.iodata_to_binary(Enum.reverse([tail | chunks]))
  end

  # Sort spans ascending, merge any overlapping OR touching span (keeping the first
  # type), so the reconstruction in redact/2 never double-cuts a byte range.
  defp merge_spans(spans) do
    spans
    |> Enum.sort()
    |> Enum.reduce([], fn
      {s, e, _t}, [{ps, pe, pt} | rest] when s <= pe -> [{ps, max(pe, e), pt} | rest]
      span, acc -> [span | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  Fail-closed post-condition: `true` if any high-confidence finding's match text
  still appears in `redacted`. Detector-agnostic (checks the actual matched text,
  not just the built-in regexes), so a gitleaks-only secret type is covered too.
  Public so the guarantee is directly testable.
  """
  @spec redaction_left_secret?([finding], String.t()) :: boolean()
  def redaction_left_secret?(findings, redacted) do
    findings
    |> Enum.filter(&high_confidence?/1)
    |> Enum.any?(fn f -> String.contains?(redacted, f.match) end)
  end

  defp high_confidence?(%{detector: :gitleaks}), do: true
  defp high_confidence?(%{secret_type: type}), do: type in @high_confidence_types

  @doc """
  Run gitleaks over `content`. Returns `{:ok, findings}` (empty on a clean exit 0,
  populated on exit 1) or `{:error, reason}` when the binary is missing/broken or
  exits unexpectedly (→ caller degrades to regex). Uses a temp file, not stdin
  (`System.cmd` has no stdin option); the file lives in a private 0700 directory
  with an unguessable name so its plaintext secrets aren't readable by other local
  users. The binary is skipped (no temp file written) if it isn't on PATH.
  """
  @spec gitleaks_scan(String.t()) :: {:ok, [finding]} | {:error, term()}
  def gitleaks_scan(content) when is_binary(content) do
    case System.find_executable(gitleaks_cmd()) do
      nil -> {:error, :gitleaks_not_found}
      path -> run_gitleaks(path, content)
    end
  end

  defp run_gitleaks(path, content) do
    dir = private_tmp_dir!()
    source = Path.join(dir, "content")
    report = Path.join(dir, "report.json")

    try do
      File.write!(source, content)
      File.chmod!(source, 0o600)

      case System.cmd(
             path,
             [
               "detect",
               "--no-git",
               "--source",
               source,
               "--report-format",
               "json",
               "--report-path",
               report
             ],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> {:ok, []}
        {_out, 1} -> {:ok, parse_gitleaks_report(File.read!(report), content)}
        # Drop the captured stderr — it can contain finding/secret text.
        {_out, code} -> {:error, {:gitleaks_exit, code}}
      end
    rescue
      e in [ErlangError, File.Error] -> {:error, {:gitleaks_unavailable, e.__struct__}}
    after
      File.rm_rf(dir)
    end
  end

  # A private (0700) temp directory with an unguessable name, created exclusively
  # (mkdir! fails if the path exists → no symlink pre-plant). The 0700 dir protects
  # the secret-bearing files inside regardless of their own mode.
  defp private_tmp_dir! do
    name = "rn-scrub-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc """
  Parse a gitleaks JSON report into findings. Locates **every** occurrence of each
  reported secret in `content` (not just the first), so duplicated secrets are all
  redacted — otherwise copies 2..N would survive as plaintext.
  """
  @spec parse_gitleaks_report(String.t(), String.t()) :: [finding]
  def parse_gitleaks_report(json, content) do
    json
    |> Jason.decode!()
    |> Enum.flat_map(&entry_to_findings(&1, content))
  end

  defp entry_to_findings(entry, content) do
    secret = entry["Secret"] || entry["Match"] || ""
    rule_id = entry["RuleID"] || "gitleaks"

    if secret == "" do
      []
    else
      content
      |> :binary.matches(secret)
      |> Enum.map(fn {start, length} ->
        %{
          detector: :gitleaks,
          rule_id: rule_id,
          secret_type: rule_id,
          start: start,
          length: length,
          match: secret
        }
      end)
    end
  end

  @doc """
  Persist an append-only `SecretFinding` audit row per finding, atomically (a bad
  changeset rolls the whole batch back rather than leaving a partial trail). Stores
  only a `sha256` of the matched text — never the raw secret. `attrs` needs
  `:source_id` and `:file_reference`; `:chunk_id` is optional.
  """
  @spec record_findings([finding], map()) :: {:ok, non_neg_integer()}
  def record_findings(findings, attrs) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Enum.each(findings, fn f ->
        %SecretFinding{}
        |> SecretFinding.changeset(%{
          source_id: attrs.source_id,
          chunk_id: Map.get(attrs, :chunk_id),
          file_reference: attrs.file_reference,
          detector: f.detector,
          rule_id: f.rule_id,
          secret_type: f.secret_type,
          span: %{"start" => f.start, "length" => f.length},
          match_hash: :crypto.hash(:sha256, f.match) |> Base.encode16(case: :lower),
          action: :redacted,
          detected_at: now
        })
        |> Repo.insert!()
      end)

      length(findings)
    end)
  end

  defp gitleaks_cmd, do: Application.get_env(:retrieval_node, :gitleaks_cmd, "gitleaks")
end
