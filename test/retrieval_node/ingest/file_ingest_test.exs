defmodule RetrievalNode.Ingest.FileIngestTest do
  # async: false — mutates the :chunking_impl/:fake_chunk_result application
  # env, and shares the SQL sandbox with the manual-mode Oban instance the
  # application tree starts.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Ingest.FileIngest
  alias RetrievalNode.Ingest.PendingChunks
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, SecretFinding, Source}

  @aws_key "AKIA1234567890ABCDEF"

  setup do
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.FakeImpl)

    on_exit(fn ->
      Application.put_env(:retrieval_node, :chunking_impl, prev)
      Application.delete_env(:retrieval_node, :fake_chunk_result)
    end)

    source = Repo.insert!(%Source{source_type: :git_repo, name: "app", identifier: "acme/app"})
    %{source: source}
  end

  defp seed_raw(source, content, natural_key, path, opts \\ []) do
    content_hash =
      Keyword.get(opts, :content_hash, "rawhash-#{System.unique_integer([:positive])}")

    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          repo: "acme/app",
          lang: "python",
          natural_key: natural_key,
          content_hash: content_hash,
          raw_content: content,
          metadata: %{"path" => path},
          force: Keyword.get(opts, :force, false)
        }
      ])

    Repo.one!(from(p in PendingChunk, order_by: [desc: p.id], limit: 1))
  end

  defp seed_deletion(source, natural_key, path) do
    {:ok, _} =
      PendingChunks.insert_raw_all([
        %{
          source: "git",
          source_id: source.id,
          source_type: "git_repo",
          natural_key: natural_key,
          metadata: %{"path" => path},
          status: "deleted"
        }
      ])

    Repo.one!(from(p in PendingChunk, order_by: [desc: p.id], limit: 1))
  end

  # Generic staging helper for non-git sources (drive_folder / jira_project),
  # so the doc_id / issue_key identity branches get real coverage.
  defp seed_row(source, attrs) do
    base = %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: "acme/app",
      lang: "python",
      content_hash: "rawhash-#{System.unique_integer([:positive])}",
      raw_content: "print('x')",
      metadata: %{}
    }

    {:ok, _} = PendingChunks.insert_raw_all([Map.merge(base, attrs)])
    Repo.one!(from(p in PendingChunk, order_by: [desc: p.id], limit: 1))
  end

  defp source_chunk_count(source),
    do: Repo.aggregate(from(c in Chunk, where: c.source_id == ^source.id), :count, :id)

  defp force_chunk(result), do: Application.put_env(:retrieval_node, :fake_chunk_result, result)

  defp chunk_result(specs) do
    chunks =
      Enum.map(specs, fn {text, breadcrumb, start_line, end_line} ->
        %{
          text: text,
          breadcrumb: breadcrumb,
          start_line: start_line,
          end_line: end_line,
          kind: "function_definition",
          parse_status: :ok
        }
      end)

    {:ok, chunks}
  end

  defp chunks_for(source, path) do
    Chunk
    |> where([c], c.source_id == ^source.id)
    |> where([c], fragment("?->>'path'", c.metadata) == ^path)
    |> Repo.all()
  end

  defp chunk_keys(source, path),
    do: chunks_for(source, path) |> Enum.map(& &1.chunk_key) |> Enum.sort()

  defp embedding_for(source, path, breadcrumb) do
    # context_breadcrumb is "<path> > <breadcrumb>" (Breadcrumb.build/2) — match
    # on the suffix rather than reconstructing the exact separator here.
    chunks_for(source, path)
    |> Enum.find(&String.ends_with?(&1.context_breadcrumb, breadcrumb))
    |> Map.fetch!(:embedding)
    |> Pgvector.to_list()
  end

  test "happy path: chunks + file_hash + embeddings + raw row deleted", %{source: source} do
    natural_key = "repo:acme/app:app.py"

    force_chunk(
      chunk_result([
        {"def a():\n    return 1\n", "a", 1, 2},
        {"def b():\n    return a()\n", "b", 4, 5}
      ])
    )

    raw = seed_raw(source, "v1", natural_key, "app.py")

    assert {:ok, summary} = FileIngest.apply(raw, [])
    assert summary.action == :indexed
    assert summary.chunks == 2
    assert summary.embedded == 2
    assert summary.reused == 0

    persisted = chunks_for(source, "app.py")
    assert length(persisted) == 2
    assert Enum.all?(persisted, &(&1.file_hash == raw.content_hash))
    assert Enum.all?(persisted, &(&1.parse_status == :ok))
    assert Enum.all?(persisted, &(&1.embedding != nil))

    refute Repo.get(PendingChunk, raw.id)
  end

  test "scrubs secrets before chunking and records an audit row for the redacted finding", %{
    source: source
  } do
    natural_key = "repo:acme/app:secret2.py"

    # Real HeuristicImpl (not the fake) so the actually-scrubbed content flows
    # through chunking.
    prev = Application.get_env(:retrieval_node, :chunking_impl)
    Application.put_env(:retrieval_node, :chunking_impl, RetrievalNode.Chunking.HeuristicImpl)
    on_exit(fn -> Application.put_env(:retrieval_node, :chunking_impl, prev) end)

    raw =
      seed_raw(
        source,
        "aws_key = #{@aws_key}\n\ndef hello():\n    return 1\n",
        natural_key,
        "secret2.py"
      )

    assert {:ok, _summary} = FileIngest.apply(raw, [])

    persisted = chunks_for(source, "secret2.py")
    assert persisted != []
    refute Enum.any?(persisted, &String.contains?(&1.content, @aws_key))

    assert Repo.aggregate(SecretFinding, :count, :id) >= 1
  end

  test "heuristic fallback on {:error, :unsupported_language}: chunks written", %{
    source: source
  } do
    natural_key = "repo:acme/app:app.rb"
    force_chunk({:error, :unsupported_language})

    raw = seed_raw(source, "some ruby content\n\nmore content here\n", natural_key, "app.rb")

    assert {:ok, summary} = FileIngest.apply(raw, [])
    assert summary.action == :indexed

    persisted = chunks_for(source, "app.rb")
    assert persisted != []
    assert Enum.all?(persisted, &(&1.parse_status == :heuristic_fallback))

    refute Repo.get(PendingChunk, raw.id)
  end

  describe "parse crash" do
    test "{:error, :boom} with default on_parse_crash: :error → {:error, :boom}, nothing written",
         %{source: source} do
      natural_key = "repo:acme/app:crash.py"
      force_chunk({:error, :boom})
      raw = seed_raw(source, "content", natural_key, "crash.py")

      assert {:error, :boom} = FileIngest.apply(raw, [])
      assert chunks_for(source, "crash.py") == []
      assert Repo.get(PendingChunk, raw.id)
    end

    test "on_parse_crash: :heuristic falls back with parse_status crashed_fallback", %{
      source: source
    } do
      natural_key = "repo:acme/app:crash2.py"
      force_chunk({:error, :boom})
      raw = seed_raw(source, "some content\n\nmore content\n", natural_key, "crash2.py")

      assert {:ok, summary} = FileIngest.apply(raw, on_parse_crash: :heuristic)
      assert summary.action == :indexed

      persisted = chunks_for(source, "crash2.py")
      assert persisted != []
      assert Enum.all?(persisted, &(&1.parse_status == :crashed_fallback))
      refute Repo.get(PendingChunk, raw.id)
    end
  end

  describe "unindexable content" do
    test "scrub cancel (content too large) reaps the raw row AND removes the file's prior chunks",
         %{source: source} do
      natural_key = "repo:acme/app:secret.py"

      force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
      raw1 = seed_raw(source, "v1", natural_key, "secret.py")
      assert {:ok, _} = FileIngest.apply(raw1, [])
      assert length(chunks_for(source, "secret.py")) == 1

      huge = String.duplicate("a", 5_000_001)
      raw2 = seed_raw(source, huge, natural_key, "secret.py")

      assert {:ok, summary} = FileIngest.apply(raw2, [])
      assert summary.action == :unindexable
      assert summary.reason == :content_too_large
      assert summary.reconciled == 1

      assert chunks_for(source, "secret.py") == []
      refute Repo.get(PendingChunk, raw2.id)
    end

    test "chunker :too_large is unindexable the same way", %{source: source} do
      natural_key = "repo:acme/app:big.py"

      force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
      raw1 = seed_raw(source, "v1", natural_key, "big.py")
      assert {:ok, _} = FileIngest.apply(raw1, [])
      assert length(chunks_for(source, "big.py")) == 1

      force_chunk({:error, :too_large})
      raw2 = seed_raw(source, "v2", natural_key, "big.py")

      assert {:ok, summary} = FileIngest.apply(raw2, [])
      assert summary.action == :unindexable
      assert summary.reason == :too_large
      assert summary.reconciled == 1

      assert chunks_for(source, "big.py") == []
      refute Repo.get(PendingChunk, raw2.id)
    end

    test "chunker :binary_content is unindexable the same way", %{source: source} do
      natural_key = "repo:acme/app:bin.py"
      force_chunk({:error, :binary_content})
      raw = seed_raw(source, "v1", natural_key, "bin.py")

      assert {:ok, summary} = FileIngest.apply(raw, [])
      assert summary.action == :unindexable
      assert summary.reason == :binary_content
      refute Repo.get(PendingChunk, raw.id)
    end
  end

  test "whitespace-only content reconciles all old chunks away", %{source: source} do
    natural_key = "repo:acme/app:empty.py"

    force_chunk(chunk_result([{"chunk a", "a", 1, 1}, {"chunk b", "b", 2, 2}]))
    raw1 = seed_raw(source, "v1", natural_key, "empty.py")
    assert {:ok, _} = FileIngest.apply(raw1, [])
    assert length(chunks_for(source, "empty.py")) == 2

    force_chunk(chunk_result([]))
    raw2 = seed_raw(source, "   \n\t\n  ", natural_key, "empty.py")

    assert {:ok, summary} = FileIngest.apply(raw2, [])
    assert summary.action == :indexed
    assert summary.chunks == 0
    assert summary.reconciled == 2
    assert summary.embedded == 0
    assert summary.reused == 0

    assert chunks_for(source, "empty.py") == []
    refute Repo.get(PendingChunk, raw2.id)
  end

  test "deletion entry removes the file's chunks (and only that file's)", %{source: source} do
    nk1 = "repo:acme/app:gone.py"
    nk2 = "repo:acme/app:stays.py"

    force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", nk1, "gone.py")
    assert {:ok, _} = FileIngest.apply(raw1, [])

    force_chunk(chunk_result([{"other chunk", "other", 1, 1}]))
    raw2 = seed_raw(source, "v1", nk2, "stays.py")
    assert {:ok, _} = FileIngest.apply(raw2, [])

    assert length(chunks_for(source, "gone.py")) == 1
    other_keys_before = chunk_keys(source, "stays.py")
    assert length(other_keys_before) == 1

    deletion = seed_deletion(source, nk1, "gone.py")
    assert deletion.status == "deleted"

    assert {:ok, %{action: :deleted, reconciled: 1}} = FileIngest.apply(deletion, [])

    assert chunks_for(source, "gone.py") == []
    assert chunk_keys(source, "stays.py") == other_keys_before
    refute Repo.get(PendingChunk, deletion.id)
  end

  test "unchanged skip: same content_hash on re-apply skips and deletes the raw row, chunks untouched",
       %{source: source} do
    natural_key = "repo:acme/app:stable.py"

    force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "stable.py", content_hash: "stable-hash")
    assert {:ok, _} = FileIngest.apply(raw1, [])

    ids_before = chunks_for(source, "stable.py") |> Enum.map(& &1.id) |> Enum.sort()

    # A re-sync that finds the same content stages a new raw row carrying the
    # identical content_hash — the unchanged-content skip is what makes that cheap.
    raw2 = seed_raw(source, "v1-again", natural_key, "stable.py", content_hash: "stable-hash")

    assert {:skipped, :unchanged} = FileIngest.apply(raw2, [])
    refute Repo.get(PendingChunk, raw2.id)

    ids_after = chunks_for(source, "stable.py") |> Enum.map(& &1.id) |> Enum.sort()
    assert ids_after == ids_before
  end

  test "force re-applies even when content_hash is unchanged", %{source: source} do
    natural_key = "repo:acme/app:forced.py"

    force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "forced.py", content_hash: "forced-hash")
    assert {:ok, _} = FileIngest.apply(raw1, [])

    raw2 = seed_raw(source, "v1-again", natural_key, "forced.py", content_hash: "forced-hash")

    assert {:ok, summary} = FileIngest.apply(raw2, force: true)
    assert summary.action == :indexed
    refute Repo.get(PendingChunk, raw2.id)
  end

  test "reconcile deletes stale keys after a boundary shift", %{source: source} do
    natural_key = "repo:acme/app:shift.py"

    force_chunk(
      chunk_result([
        {"chunk a", "a", 1, 1},
        {"chunk b", "b", 2, 2},
        {"chunk c", "c", 3, 3}
      ])
    )

    raw1 = seed_raw(source, "v1", natural_key, "shift.py")
    assert {:ok, _} = FileIngest.apply(raw1, [])
    original_keys = chunk_keys(source, "shift.py")
    assert length(original_keys) == 3

    # A def removed earlier in the file shifts every breadcrumb after it — the
    # new chunk set shares no keys with the old one.
    force_chunk(
      chunk_result([
        {"chunk a2", "a2", 1, 1},
        {"chunk b2", "b2", 2, 2}
      ])
    )

    raw2 = seed_raw(source, "v2", natural_key, "shift.py")
    assert {:ok, summary} = FileIngest.apply(raw2, [])
    assert summary.reconciled == 3

    new_keys = chunk_keys(source, "shift.py")
    assert length(new_keys) == 2
    assert Enum.all?(new_keys, &(&1 not in original_keys))
  end

  test "embedding reuse: unchanged chunks keep their vector, changed chunk gets a new one", %{
    source: source
  } do
    natural_key = "repo:acme/app:reuse.py"

    force_chunk(
      chunk_result([
        {"chunk a stable text", "a", 1, 1},
        {"chunk b version one", "b", 2, 2}
      ])
    )

    raw1 = seed_raw(source, "v1", natural_key, "reuse.py")
    assert {:ok, summary1} = FileIngest.apply(raw1, [])
    assert summary1.embedded == 2
    assert summary1.reused == 0

    vector_a_before = embedding_for(source, "reuse.py", "a")
    vector_b_before = embedding_for(source, "reuse.py", "b")

    force_chunk(
      chunk_result([
        # unchanged text, same breadcrumb → same chunk_key AND same content_hash
        {"chunk a stable text", "a", 1, 1},
        # edited text, same breadcrumb/key → content_hash differs
        {"chunk b version two", "b", 2, 2}
      ])
    )

    raw2 = seed_raw(source, "v2", natural_key, "reuse.py")
    assert {:ok, summary2} = FileIngest.apply(raw2, [])
    assert summary2.embedded == 1
    assert summary2.reused == 1

    vector_a_after = embedding_for(source, "reuse.py", "a")
    vector_b_after = embedding_for(source, "reuse.py", "b")

    assert vector_a_after == vector_a_before
    refute vector_b_after == vector_b_before
  end

  test "embedding reuse skips a stored chunk whose embedding is nil (re-embeds it)", %{
    source: source
  } do
    natural_key = "repo:acme/app:nilemb.py"

    force_chunk(chunk_result([{"chunk a stable text", "a", 1, 1}]))
    raw1 = seed_raw(source, "v1", natural_key, "nilemb.py")
    assert {:ok, %{embedded: 1, reused: 0}} = FileIngest.apply(raw1, [])

    # Simulate a prior row persisted without an embedding (Chunk.embedding is
    # nullable) — reuse must NOT copy the nil forward; it must re-embed.
    [chunk] = chunks_for(source, "nilemb.py")
    Repo.update_all(from(c in Chunk, where: c.id == ^chunk.id), set: [embedding: nil])

    force_chunk(chunk_result([{"chunk a stable text", "a", 1, 1}]))
    raw2 = seed_raw(source, "v2", natural_key, "nilemb.py")
    assert {:ok, %{embedded: 1, reused: 0}} = FileIngest.apply(raw2, [])

    [chunk_after] = chunks_for(source, "nilemb.py")
    refute is_nil(chunk_after.embedding)
  end

  describe "unresolvable file identity" do
    test "a deletion entry with blank identity is rejected and its row survives", %{
      source: source
    } do
      # A deletion carrying no path can't be reconciled — apply/2 must reject it
      # (leaving the row for diagnosis) rather than reap it and report success.
      deletion = seed_deletion(source, "repo:acme/app:mystery", "gone.py")
      {:ok, _} = Repo.update(Ecto.Changeset.change(deletion, metadata: %{}))
      deletion = Repo.get!(PendingChunk, deletion.id)

      assert {:error, :no_file_identity} = FileIngest.apply(deletion, [])
      assert Repo.get(PendingChunk, deletion.id)
    end

    test "a content row with blank identity is rejected and its row survives", %{source: source} do
      force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
      raw = seed_raw(source, "v1", "repo:acme/app:mystery.py", "mystery.py")
      {:ok, _} = Repo.update(Ecto.Changeset.change(raw, metadata: %{}))
      raw = Repo.get!(PendingChunk, raw.id)

      assert {:error, :no_file_identity} = FileIngest.apply(raw, [])
      assert Repo.get(PendingChunk, raw.id)
    end
  end

  describe "source-specific identity (drive folder, jira project)" do
    test "drive: deletion by doc_id reconciles that document's chunks away" do
      drive =
        Repo.insert!(%Source{source_type: :drive_folder, name: "docs", identifier: "folder/1"})

      force_chunk(chunk_result([{"doc body", "b", 1, 1}]))

      raw =
        seed_row(drive, %{
          source: "drive",
          source_type: "drive_folder",
          natural_key: "drive:#{drive.id}:doc-1",
          metadata: %{"doc_id" => "doc-1"}
        })

      assert {:ok, %{action: :indexed, chunks: 1}} = FileIngest.apply(raw, [])
      assert source_chunk_count(drive) == 1

      deletion =
        seed_row(drive, %{
          source: "drive",
          source_type: "drive_folder",
          status: "deleted",
          content_hash: nil,
          raw_content: nil,
          natural_key: "drive:#{drive.id}:doc-1",
          metadata: %{"doc_id" => "doc-1"}
        })

      assert {:ok, %{action: :deleted, reconciled: 1}} = FileIngest.apply(deletion, [])
      assert source_chunk_count(drive) == 0
    end

    test "jira: unchanged-skip and boundary-shift reconcile key on issue_key" do
      jira = Repo.insert!(%Source{source_type: :jira_project, name: "proj", identifier: "PROJ"})

      force_chunk(chunk_result([{"c1", "a", 1, 1}, {"c2", "b", 2, 2}]))

      raw1 =
        seed_row(jira, %{
          source: "jira",
          source_type: "jira_project",
          natural_key: "jira:PROJ:PROJ-1",
          content_hash: "issue-h1",
          metadata: %{"issue_key" => "PROJ-1"}
        })

      assert {:ok, %{action: :indexed, chunks: 2}} = FileIngest.apply(raw1, [])
      assert source_chunk_count(jira) == 2

      # Same content_hash on the same issue_key → the unchanged skip fires
      # (proving the issue_key identity query, not just path, is wired).
      raw_same =
        seed_row(jira, %{
          source: "jira",
          source_type: "jira_project",
          natural_key: "jira:PROJ:PROJ-1",
          content_hash: "issue-h1",
          metadata: %{"issue_key" => "PROJ-1"}
        })

      assert {:skipped, :unchanged} = FileIngest.apply(raw_same, [])

      # Fewer chunks than before → the dropped chunk's stale row is reconciled
      # away, scoped by issue_key.
      force_chunk(chunk_result([{"c1", "a", 1, 1}]))

      raw2 =
        seed_row(jira, %{
          source: "jira",
          source_type: "jira_project",
          natural_key: "jira:PROJ:PROJ-1",
          content_hash: "issue-h2",
          metadata: %{"issue_key" => "PROJ-1"}
        })

      assert {:ok, %{action: :indexed, chunks: 1, reconciled: 1}} = FileIngest.apply(raw2, [])
      assert source_chunk_count(jira) == 1
    end
  end

  describe "audit rows ride the terminal transaction" do
    test "a parse crash writes no secret_finding (nothing to duplicate on retry)", %{
      source: source
    } do
      # Scrub redacts the key (findings present), then chunking crashes →
      # {:error}. The row survives and NO audit row is committed, so a retry
      # can't accumulate duplicate findings.
      force_chunk({:error, :boom})
      raw = seed_raw(source, "key = \"#{@aws_key}\"", "repo:acme/app:crash.py", "crash.py")

      assert {:error, :boom} = FileIngest.apply(raw, [])
      assert Repo.aggregate(SecretFinding, :count, :id) == 0
      assert Repo.get(PendingChunk, raw.id)
    end

    test "a successful ingest commits the redacted-secret audit row", %{source: source} do
      force_chunk(chunk_result([{"chunk a", "a", 1, 1}]))
      raw = seed_raw(source, "key = \"#{@aws_key}\"", "repo:acme/app:sec.py", "sec.py")

      assert {:ok, %{action: :indexed}} = FileIngest.apply(raw, [])
      assert Repo.aggregate(SecretFinding, :count, :id) == 1
    end
  end
end
