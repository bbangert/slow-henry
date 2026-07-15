---
module: "Embedding.Serving"
date: "2026-07-15"
problem_type: integration_issue
component: configuration
symptoms:
  - "Postgrex ERROR 22000 (data_exception) vector must have at least 1 dimension on UPDATE of a vector(384) column"
  - "** (MatchError) no match of right hand side value in Pgvector.to_list/1 while Ecto formats the debug SQL log line"
  - "Every EmbedBatch Oban job retryable/discarded; 0 completed; chunks table stays empty while pending_chunks fills"
  - "warmup/healthz report ready — the failure only appears at DB write time"
root_cause: "Bumblebee.Text.TextEmbedding.text_embedding was configured with output_attribute: :hidden_state but NO output_pool, so the serving returned the full padded {sequence_length, 768} hidden-state tensor per text instead of one pooled {768} embedding; Matryoshka truncation then flattened it to seq_len*384 = 196,608 floats, and pgvector's binary wire format stores dimensions as uint16 — 196608 = 3 x 65536 overflows to exactly 0"
severity: critical
tags: [bumblebee, nx-serving, pgvector, embeddings, mean-pooling, uint16-overflow, matryoshka, integration-tests]
elixir_version: "1.20.2"
---

# Missing `output_pool: :mean_pooling` → pgvector uint16 dim header overflows to 0

## Symptoms

- `Postgrex.Error 22000: vector must have at least 1 dimension` from
  `PendingChunks.update_embedding/2` — nonsensical, since the code clearly built
  a non-empty float list.
- On other attempts of the same job: `MatchError` in `Pgvector.to_list/1`
  raised *while Ecto logged the failing query's parameters* (the malformed
  binary can't round-trip), masking the real error.
- Systemic: **zero** `EmbedBatch` jobs ever completed; query-side
  `semantic_search` equally broken.
- Everything upstream looked healthy: warmup succeeded, `/healthz` green —
  neither ever checked the *dimensions* of what the serving produced.

## Investigation

1. **Hypothesis: empty/degenerate chunk content** — checked the failing
   `pending_chunk` row: 273 chars of normal text. Not the data.
2. **Hypothesis: flaky serving result handling** — the two different errors
   across attempts suggested nondeterminism, but both are consistent with ONE
   malformed vector: `Pgvector.new(list)` encodes length as **uint16**, so a
   196,608-element list encodes as dim `0` (PG rejects: "at least 1 dimension")
   and the resulting struct's binary can't be decoded by `Pgvector.to_list/1`
   (MatchError during Ecto param logging).
3. **Root cause found**: live repro — `Nx.Serving.batched_run(name, ["hello"])`
   returned `%{embedding: #Nx.Tensor<f32[512][768]>}` per text: the **unpooled,
   padded hidden-state sequence**. `output_attribute: :hidden_state` without
   `output_pool` means no pooling is applied. 512 × 384 (post-Matryoshka)
   = 196,608 = 3 × 65,536 → uint16 ≡ 0. The design doc's code sketch had the
   identical omission — the bug was faithfully implemented from the design.

## Root Cause

nomic-embed-text-v1.5 (like most sentence embedders) requires **masked mean
pooling** over the final hidden state. Bumblebee does not default this on when
you select `output_attribute: :hidden_state`; you must ask for it.

```elixir
# BROKEN — emits {seq_len, 768} per text
TextEmbedding.text_embedding(model_info, tokenizer,
  compile: [batch_size: b, sequence_length: s],
  defn_options: [compiler: EXLA],
  output_attribute: :hidden_state,
  embedding_processor: :l2_norm
)
```

## Solution

```elixir
# FIXED — attention-mask-aware mean pooling → {768} per text
TextEmbedding.text_embedding(model_info, tokenizer,
  compile: [batch_size: b, sequence_length: s],
  defn_options: [compiler: EXLA],
  output_attribute: :hidden_state,
  output_pool: :mean_pooling,
  embedding_processor: :l2_norm
)
```

Plus loud guards so this class of failure can never reach the DB again:
`matryoshka/1` raises on a rank-2 tensor (names `output_pool` in the message)
or a <384-dim result; `warmup/0` embeds through the full production path and
only flips the readiness flag if the result has exactly 384 dims.

### Files Changed

- `lib/retrieval_node/embedding/serving.ex` — `output_pool: :mean_pooling`; warmup dim assert
- `lib/retrieval_node/embedding/nx_serving_impl.ex` — matryoshka rank/length guards
- `.claude/plans/retrieval-node/research/design-otp.md` §2.1 — fixed the sketch + warning comment

## Prevention

- **Run the real-model `:integration` tests whenever serving options change** —
  they assert 384 dims and would have caught this instantly; they're excluded
  by default and had never run against the real model.
- Warmup/readiness checks must validate *output shape*, not just "a call
  succeeded".
- Treat design-doc API sketches as unverified until an integration test
  exercises them.
- pgvector gotcha worth remembering: the wire format's dim header is uint16 —
  oversized vectors can alias to absurd dims (including 0) instead of failing
  with a size error.

## Related

- `.claude/solutions/oban-issues/upsert-chunks-to-existing-atom-lazy-loading-20260715.md` — unmasked by this fix
