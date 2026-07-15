---
module: "Ingest.Workers.UpsertChunks"
date: "2026-07-15"
problem_type: oban_issue
component: oban_worker
symptoms:
  - "** (ArgumentError) not an already existing atom from String.to_existing_atom/1 inside an Oban worker"
  - "All UpsertChunks jobs discarded under `mix run`; the SAME code passes the full test suite"
root_cause: "String.to_existing_atom(\"heuristic_fallback\") ran before any module that interns that atom was loaded — under mix run's lazy module loading, atom existence depends on incidental load order, so code that works in mix test (where test files force-load everything) crashes in production-style boots"
severity: high
tags: [to-existing-atom, lazy-loading, ecto-enum, oban-worker, atom-exhaustion, mix-run]
elixir_version: "1.20.2"
---

# `String.to_existing_atom/1` fails under lazy module loading — use `Ecto.Enum.mappings/2`

## Symptoms

Every `UpsertChunks` job discarded with `ArgumentError: not an already existing
atom` when converting staged enum strings (`"heuristic_fallback"`) back to
atoms — but only under `mix run`/release-style boots. `mix test` was green.

## Investigation

1. Latent until the embedding stage was fixed — UpsertChunks had simply never
   executed before (upstream failure masked it).
2. Why tests passed: the test suite loads virtually every module, so the atom
   was always interned by *something* before the worker ran. Under `mix run`,
   modules load lazily; nothing had interned `:heuristic_fallback` yet.

## Root Cause

`String.to_existing_atom/1` is only as safe as the guarantee that some loaded
module already interned the atom — under lazy loading that guarantee is
load-order roulette. The atom-exhaustion concern it addresses is real, but the
mechanism is wrong when an authoritative allowlist exists.

## Solution

Resolve staged strings through the Ecto schema's own enum mapping — it forces
the schema module load, is a closed allowlist, never mints atoms, and rejects
unknown values descriptively:

```elixir
defp to_enum(field, value) when is_binary(value) do
  mappings = Ecto.Enum.mappings(RetrievalNode.Retrieval.Chunk, field)

  case Enum.find(mappings, fn {_atom, string} -> string == value end) do
    {atom, _} -> atom
    nil -> raise ArgumentError, "unknown #{field} value: #{inspect(value)}"
  end
end
```

### Files Changed

- `lib/retrieval_node/ingest/workers/upsert_chunks.ex` — `to_enum/2` via `Ecto.Enum.mappings/2`

## Prevention

- Never `String.to_existing_atom/1` for values that belong to an Ecto enum —
  `Ecto.Enum.mappings/2` is the authoritative, load-forcing allowlist.
- Distrust "passes in test, fails in prod boot" for anything atom-related:
  test suites intern atoms as a side effect of loading everything.
- Smoke-test workers under `mix run` (lazy loading), not only under the suite.

## Related

- `.claude/solutions/phoenix-issues/vector-zero-dimensions-missing-output-pool-embedding-20260715.md` — the upstream fix that unmasked this
