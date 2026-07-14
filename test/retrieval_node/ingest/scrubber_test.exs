defmodule RetrievalNode.Ingest.ScrubberTest do
  use RetrievalNode.DataCase, async: true

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
      pem =
        "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAExyz\n-----END RSA PRIVATE KEY-----"

      assert [%{secret_type: "private_key"}] = Scrubber.regex_scan(pem)
    end

    test "returns [] for content with no secrets" do
      assert Scrubber.regex_scan("just a normal sentence about databases") == []
    end
  end

  describe "redact/2" do
    test "replaces the secret span in place and removes the plaintext (byte-correct)" do
      content = "aws = #{@aws_key} end"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))

      refute String.contains?(redacted, @aws_key)
      assert redacted == "aws = [REDACTED:aws_access_key_id] end"
    end

    test "handles multiple findings on one line without offset drift" do
      content = "a #{@aws_key} b ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 c"
      redacted = Scrubber.redact(content, Scrubber.regex_scan(content))

      refute String.contains?(redacted, @aws_key)
      refute String.contains?(redacted, "ghp_")
      assert String.contains?(redacted, "[REDACTED:aws_access_key_id]")
      assert String.contains?(redacted, "[REDACTED:github_token]")
      assert String.starts_with?(redacted, "a ") and String.ends_with?(redacted, " c")
    end
  end

  describe "scrub/2 policy" do
    test "git source degrades to regex when gitleaks is absent, and still redacts" do
      {:ok, result} = Scrubber.scrub("token AKIA1234567890ABCDEF\n", :git_repo)

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
        fn _event, meas, _meta, pid -> send(pid, {:degraded, meas}) end,
        self()
      )

      Scrubber.scrub("hello", :git_repo)
      assert_receive {:degraded, %{count: 1}}
    end

    test "jira/drive text is scanned by regex directly (clean → :clean)" do
      assert {:ok, %{scrub_mode: "regex", secrets_status: :clean}} =
               Scrubber.scrub("a normal jira comment", :jira_project)

      assert {:ok, %{scrub_mode: "regex", secrets_status: :redacted}} =
               Scrubber.scrub("password = #{@aws_key}", :drive_folder)
    end

    test "fail-closed: no high-confidence secret survives in the redacted output" do
      {:ok, result} = Scrubber.scrub("k=#{@aws_key} db=postgres://u:p@h/d", :git_repo)

      # Re-scanning the redacted content finds no high-confidence secret.
      assert Enum.all?(Scrubber.regex_scan(result.redacted_content), fn f ->
               f.secret_type == "generic_secret"
             end)
    end
  end

  describe "record_findings/2 (audit log)" do
    test "writes SecretFinding rows with a sha256 hash — never the raw secret" do
      source = Repo.insert!(%Source{source_type: :git_repo, name: "r", identifier: "r"})
      findings = Scrubber.regex_scan("key #{@aws_key}")

      assert {:ok, 1} =
               Scrubber.record_findings(findings, %{
                 source_id: source.id,
                 file_reference: "lib/x.ex"
               })

      [row] = Repo.all(SecretFinding)
      expected = :crypto.hash(:sha256, @aws_key) |> Base.encode16(case: :lower)

      assert row.match_hash == expected
      assert row.secret_type == "aws_access_key_id"
      assert row.detector == :regex_scanner
      assert row.action == :redacted
      assert row.file_reference == "lib/x.ex"
      # The raw secret must appear in NO column.
      refute row.match_hash == @aws_key
    end
  end

  describe "parse_gitleaks_report/2" do
    test "maps gitleaks JSON to findings and locates byte offsets in content" do
      content = "line one\nsecret is AKIA1234567890ABCDEF here\n"
      json = ~s([{"RuleID":"aws-access-key","Secret":"#{@aws_key}","StartLine":2}])

      assert [finding] = Scrubber.parse_gitleaks_report(json, content)
      assert finding.detector == :gitleaks
      assert finding.rule_id == "aws-access-key"
      assert binary_part(content, finding.start, finding.length) == @aws_key
    end

    test "skips a reported secret whose text isn't found in content" do
      json = ~s([{"RuleID":"x","Secret":"NOTPRESENT"}])
      assert Scrubber.parse_gitleaks_report(json, "clean content") == []
    end
  end
end
