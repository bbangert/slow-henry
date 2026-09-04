# Ingest.SourceOwner test-env toggles (Phase 3 moves these to config/test.exs —
# deferred for now because the app under test is a long-lived dev node whose
# config/*.exs can't be edited without a restart; see the plan). Must be set
# BEFORE ExUnit.start, because the app is already running by the time this
# file executes (Mix boots it ahead of the test suite) — put_env here still
# lands before any test's setup reads it.
#
#   :source_owner_notify false — discovery-worker tests (RepoSync/DriveSync/
#   JiraSync) must not spawn owner processes that then race the DataCase
#   sandbox; owner tests (source_owner_test.exs) start owners explicitly via
#   SourceOwner.drain/1 or DynamicSupervisor.start_child/2 and opt back in
#   per-test where they need notify/1 itself under test.
#
#   :ingest_resume_on_boot false — the boot resume Task is otherwise also
#   gated on Oban's testing: :manual (Ingest.Supervisor's ingest_vm?/0), which
#   already covers the test env; setting this explicitly is belt-and-suspenders
#   and documents the intent independently of that second gate.
Application.put_env(:retrieval_node, :source_owner_notify, false)
Application.put_env(:retrieval_node, :ingest_resume_on_boot, false)

# Exclude tests tagged :integration by default (they load the embedding model +
# EXLA, which is slow and network-dependent). Run them with:
#   mix test --include integration
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(RetrievalNode.Repo, :manual)
