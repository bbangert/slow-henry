defmodule RetrievalNode.Ingest.ScrubberTest do
  # async: false — this module mutates global application env (`:gitleaks_cmd`)
  # and attaches telemetry handlers, which would race under concurrent tests.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Ingest.Scrubber
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{SecretFinding, Source}

  @aws_key "AKIA1234567890ABCDEF"

  describe "regex_scan/1" do
    test "detects a planted AWS access key with byte offset + length" do
      content = "key = #{@aws_key}\n"
      assert [finding] = Scrubber.regex_scan(content)

      assert finding.secret_type == "aws_access_key_id"
      assert finding.detector == :regex_scanner
      assert finding.match == @aws_key
      assert binary_part(content, finding.start, finding.length) == @aws_key
    end

    test "detects a PEM private key block" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAExyz\n-----END RSA PRIVATE KEY-----"
      assert [%{secret_type: "private_key"}] = Scrubber.regex_scan(pem)
    end

    test "returns [] for content with no secrets" do
      assert Scrubber.regex_scan("just a normal sentence about databases") == []
    end

    test "detects EVERY occurrence of a repeated secret (no first-match collapse)" do
      content = "a #{@aws_key} b #{@aws_key} c"
      assert [f1, f2] = Scrubber.regex_scan(content)
      refute f1.start == f2.start
    end
  end

  describe "redact/2" do
    test "replaces the secret span in place and removes the plaintext (byte-correct)" do
      content = "aws = #{@aws_key} end"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))

      refute String.contains?(redacted, @aws_key)
      assert redacted == "aws = [REDACTED:aws_access_key_id] end"
    end

    test "removes ALL copies of a repeated secret" do
      content = "#{@aws_key} and again #{@aws_key}"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))
      refute String.contains?(redacted, @aws_key)
    end

    test "handles multiple distinct findings on one line without offset drift" do
      content = "a #{@aws_key} b ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 c"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))

      refute String.contains?(redacted, @aws_key)
      refute String.contains?(redacted, "ghp_")
      assert String.starts_with?(redacted, "a ") and String.ends_with?(redacted, " c")
    end

    test "byte offsets stay correct after a multibyte UTF-8 character" do
      content = "€ prefix #{@aws_key} suffix"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))

      refute String.contains?(redacted, @aws_key)
      assert String.starts_with?(redacted, "€ prefix [REDACTED:")
      assert String.valid?(redacted)
    end

    test "merges overlapping spans without corrupting the output" do
      content = "xx #{@aws_key} yy"

      overlapping = [
        %{start: 3, length: 20, secret_type: "aws_access_key_id"},
        %{start: 10, length: 13, secret_type: "generic_secret"}
      ]

      redacted = Scrubber.redact(content, overlapping)
      refute String.contains?(redacted, @aws_key)
      assert redacted == "xx [REDACTED:aws_access_key_id] yy"
    end
  end

  describe "redaction_left_secret?/2 (fail-closed post-condition)" do
    test "true when a high-confidence match still appears in the redacted content" do
      findings = [%{detector: :regex_scanner, secret_type: "aws_access_key_id", match: @aws_key}]
      assert Scrubber.redaction_left_secret?(findings, "leftover #{@aws_key}")
    end

    test "true for a surviving gitleaks-detected secret of any rule type" do
      findings = [%{detector: :gitleaks, secret_type: "custom-rule", match: "s3cr3t-token"}]
      assert Scrubber.redaction_left_secret?(findings, "s3cr3t-token still here")
    end

    test "false when the high-confidence secret is gone" do
      findings = [%{detector: :regex_scanner, secret_type: "aws_access_key_id", match: @aws_key}]
      refute Scrubber.redaction_left_secret?(findings, "all [REDACTED:aws_access_key_id] clean")
    end

    test "false for a surviving generic_secret (excluded from high-confidence)" do
      findings = [%{detector: :regex_scanner, secret_type: "generic_secret", match: "hunter2xx"}]
      refute Scrubber.redaction_left_secret?(findings, "still hunter2xx around")
    end
  end

  describe "scrub/2 policy" do
    setup do
      # Force the gitleaks path to fail deterministically (regardless of whether
      # gitleaks is installed on this machine) so the degrade path is exercised.
      prev = Application.get_env(:retrieval_node, :gitleaks_cmd)
      Application.put_env(:retrieval_node, :gitleaks_cmd, "no-such-gitleaks-binary-xyz")
      on_exit(fn -> Application.put_env(:retrieval_node, :gitleaks_cmd, prev) end)
      :ok
    end

    test "git source degrades to regex when gitleaks is unavailable, and still redacts" do
      {:ok, result} = Scrubber.scrub("token #{@aws_key}\n", :git_repo)

      assert result.scrub_mode == "gitleaks_degraded_regex"
      assert result.secrets_status == :redacted
      refute String.contains?(result.redacted_content, @aws_key)
    end

    test "git degrade emits the :scrub :degraded telemetry event" do
      handler = "scrub-degraded-#{inspect(self())}"
      on_exit(fn -> :telemetry.detach(handler) end)

      :telemetry.attach(
        handler,
        [:retrieval_node, :scrub, :degraded],
        fn _e, meas, _meta, pid -> send(pid, {:degraded, meas}) end,
        self()
      )

      Scrubber.scrub("hello", :git_repo)
      assert_receive {:degraded, %{count: 1}}
    end

    test "jira/drive text is scanned by regex directly" do
      assert {:ok, %{scrub_mode: "regex", secrets_status: :clean}} =
               Scrubber.scrub("a normal jira comment", :jira_project)

      assert {:ok, %{scrub_mode: "regex", secrets_status: :redacted}} =
               Scrubber.scrub("password = #{@aws_key}", :drive_folder)
    end

    test "no high-confidence secret survives in the redacted output" do
      {:ok, result} = Scrubber.scrub("k=#{@aws_key} db=postgres://u:p@h/d", :git_repo)
      refute Scrubber.redaction_left_secret?(result.findings, result.redacted_content)
    end

    test "content over the size cap is discarded (fail-closed), not scanned" do
      huge = String.duplicate("x", 5_000_001)
      assert {:cancel, :content_too_large} = Scrubber.scrub(huge, :jira_project)
    end
  end

  describe "record_findings/2 (audit log)" do
    test "writes SecretFinding rows with a sha256 hash — the raw secret is in NO column" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "r", identifier: "r"})
      findings = Scrubber.regex_scan("key #{@aws_key}")

      assert {:ok, 1} =
               Scrubber.record_findings(findings, %{
                 source_id: source.id,
                 file_reference: "lib/x.ex"
               })

      [row] = Repo.all(SecretFinding)
      assert row.match_hash == :crypto.hash(:sha256, @aws_key) |> Base.encode16(case: :lower)
      assert row.secret_type == "aws_access_key_id"
      assert row.action == :redacted

      # Whole-row check: the raw secret must not appear in any field's string form.
      row_dump = row |> Map.from_struct() |> Map.drop([:__meta__]) |> inspect()
      refute String.contains?(row_dump, @aws_key)
    end
  end

  describe "parse_gitleaks_report/2" do
    test "maps gitleaks JSON to findings and locates byte offsets in content" do
      content = "line one\nsecret is #{@aws_key} here\n"
      json = ~s([{"RuleID":"aws-access-key","Secret":"#{@aws_key}","StartLine":2}])

      assert [finding] = Scrubber.parse_gitleaks_report(json, content)
      assert finding.detector == :gitleaks
      assert binary_part(content, finding.start, finding.length) == @aws_key
    end

    test "emits a finding for EVERY occurrence of a duplicated secret" do
      content = "#{@aws_key} ... #{@aws_key}"
      json = ~s([{"RuleID":"aws","Secret":"#{@aws_key}"}])

      assert [a, b] = Scrubber.parse_gitleaks_report(json, content)
      refute a.start == b.start
    end

    test "skips a reported secret whose text isn't found in content" do
      json = ~s([{"RuleID":"x","Secret":"NOTPRESENT"}])
      assert Scrubber.parse_gitleaks_report(json, "clean content") == []
    end
  end
end
