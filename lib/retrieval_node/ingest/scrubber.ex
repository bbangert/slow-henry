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
  rather than indexed — the "never index a plaintext secret" guarantee. Audit rows
  store only a `sha256` of the match, never the raw secret.
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

  # Patterns whose presence AFTER redaction means we failed to scrub a real secret
  # → discard rather than index (fail-closed). The generic catch-all is excluded
  # (too noisy to hard-fail on).
  @high_confidence_types ~w(aws_access_key_id gcp_api_key github_token slack_token jwt private_key connection_string)

  @doc """
  Scrub `content` for the given `source_type`. Returns `{:ok, result}` (possibly
  with `secrets_status: :redacted`), `{:cancel, reason}` if a high-confidence
  secret survives redaction, or `{:error, reason}` if no scan could run at all.
  """
  @spec scrub(String.t(), atom()) :: {:ok, result} | {:cancel, atom()} | {:error, atom()}
  def scrub(content, :git_repo) when is_binary(content) do
    case gitleaks_scan(content) do
      {:ok, findings} ->
        finish(content, findings, "gitleaks")

      {:error, reason} ->
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
    # scanned this content — the true fail-closed terminal state.
    e ->
      Logger.error("regex scrub raised: #{inspect(e)}")
      {:error, :scrub_unavailable}
  end

  # Common tail: redact, then fail-closed verify that no high-confidence secret
  # survived, then build the result.
  defp finish(content, findings, scrub_mode) do
    redacted = redact(content, findings)

    if high_confidence_survives?(redacted) do
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

    {chunks, pos} =
      Enum.reduce(spans, {[], 0}, fn {s, e, type}, {acc, pos} ->
        prefix = binary_part(content, pos, s - pos)
        {[["[REDACTED:", type, "]"], prefix | acc], e}
      end)

    tail = binary_part(content, pos, byte_size(content) - pos)
    IO.iodata_to_binary(Enum.reverse([tail | chunks]))
  end

  # Sort spans ascending, merge any overlaps (keeping the first type), so the
  # reconstruction in redact/2 never double-cuts a byte range.
  defp merge_spans(spans) do
    spans
    |> Enum.sort()
    |> Enum.reduce([], fn
      {s, e, _t}, [{ps, pe, pt} | rest] when s <= pe -> [{ps, max(pe, e), pt} | rest]
      span, acc -> [span | acc]
    end)
    |> Enum.reverse()
  end

  defp high_confidence_survives?(content) do
    Enum.any?(@patterns, fn {type, _rule, regex} ->
      type in @high_confidence_types and Regex.match?(regex, content)
    end)
  end

  @doc """
  Run gitleaks over `content`. Returns `{:ok, findings}` (empty on a clean exit 0,
  populated on exit 1) or `{:error, reason}` when the binary is missing/broken or
  exits unexpectedly (→ caller degrades to regex). Uses a temp file, not stdin
  (`System.cmd` has no stdin option).
  """
  @spec gitleaks_scan(String.t()) :: {:ok, [finding]} | {:error, term()}
  def gitleaks_scan(content) when is_binary(content) do
    source = Path.join(System.tmp_dir!(), "scrub-#{:erlang.unique_integer([:positive])}.txt")
    report = source <> ".json"

    try do
      File.write!(source, content)

      case System.cmd(
             "gitleaks",
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
        {out, code} -> {:error, {:gitleaks_exit, code, out}}
      end
    rescue
      e in [ErlangError, File.Error] -> {:error, {:gitleaks_unavailable, e}}
    after
      File.rm(source)
      File.rm(report)
    end
  end

  @doc """
  Parse a gitleaks JSON report into findings, locating each secret's byte offset
  in `content` by its reported `Match`/`Secret` text.
  """
  @spec parse_gitleaks_report(String.t(), String.t()) :: [finding]
  def parse_gitleaks_report(json, content) do
    json
    |> Jason.decode!()
    |> Enum.flat_map(fn entry ->
      secret = entry["Secret"] || entry["Match"] || ""

      case secret != "" and :binary.match(content, secret) do
        {start, length} ->
          [
            %{
              detector: :gitleaks,
              rule_id: entry["RuleID"] || "gitleaks",
              secret_type: entry["RuleID"] || "secret",
              start: start,
              length: length,
              match: secret
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  Persist an append-only `SecretFinding` audit row per finding. Stores only a
  `sha256` of the matched text — never the raw secret. `attrs` needs `:source_id`
  and `:file_reference`; `:chunk_id` is optional (nil until chunks are written).
  """
  @spec record_findings([finding], map()) :: {:ok, non_neg_integer()}
  def record_findings(findings, attrs) do
    now = DateTime.utc_now()

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

    {:ok, length(findings)}
  end
end
