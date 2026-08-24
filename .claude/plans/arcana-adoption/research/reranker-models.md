# Cross-Encoder Rerankers Under Bumblebee/Nx.Serving

Date: 2026-08-18. Context: nomic-embed-text-v1.5 embeddings already run under Bumblebee/EXLA;
evaluating cross-encoder rerankers for top-50 candidate reranking of ~300k code chunks,
CPU latency budget 100-300ms.

## 1. Bumblebee architecture support

Bumblebee (v0.7.x/v0.7.1 per hexdocs) ships a fixed set of `Bumblebee.Text.*` architecture
modules. Confirmed list from the current API reference: ALBERT, BART, BERT, Blenderbot,
DistilBERT, Gemma, Gemma 3, GPT-2, GPT-BigCode, GPT-NeoX, LLaMA, M2M100, mBART, Mistral,
ModernBERT, MPNet, Nomic BERT, Phi, Phi-3, Qwen3, RoBERTa, SmolLM3, T5. **[T1]**
(https://bumblebee.hexdocs.pm/api-reference.html)

Key facts:

- **`Bumblebee.Text.Bert` supports `:for_sequence_classification`.** This is the head used
  for cross-encoders (a single-logit or softmax classification head over the `[CLS]`
  representation of a concatenated query+passage pair).
- **XLM-RoBERTa is NOT a supported architecture module.** Only plain `RoBERTa` is listed;
  there is no `Bumblebee.Text.XlmRoberta`. `BAAI/bge-reranker-base` and
  `BAAI/bge-reranker-v2-m3` are both `XLMRobertaForSequenceClassification` checkpoints
  (confirmed via their HF model cards and by the vLLM-Ascend bug report explicitly citing
  "Text-only XLMRobertaForSequenceClassification not be supported" **[T1/T3]**
  https://huggingface.co/BAAI/bge-reranker-v2-m3,
  https://github.com/vllm-project/vllm-ascend/issues/1960). Since Bumblebee has no
  XLM-RoBERTa architecture at all, **bge-reranker-base and bge-reranker-v2-m3 cannot be
  loaded by Bumblebee today**, regardless of the sequence-classification head. This would
  require someone to add an `XlmRoberta` architecture module to Bumblebee first (it's
  structurally very close to RoBERTa — same encoder, different vocab/tokenizer size —
  so it's plausible future work, but no PR or issue for it exists as of this research).
- **`jina-reranker-v2-base-multilingual` requires `trust_remote_code=True`** when loaded via
  `AutoModelForSequenceClassification` in Python — it ships custom modeling code, not a
  standard architecture **[T1]** (HF model card / loading instructions). Bumblebee has no
  mechanism analogous to `trust_remote_code` (it maps HF config `model_type` to a fixed
  Elixir module). **Confirmed: not loadable in Bumblebee.**
- **`mixedbread-ai/mxbai-rerank-*-v1`** models are built on **DeBERTa-v2** **[T3]**
  (search-aggregated from HF/PromptLayer pages). DeBERTa-v2 is not in Bumblebee's supported
  list either — **not loadable.**
- **`cross-encoder/ms-marco-MiniLM-L-6-v2`** is a standard BERT checkpoint
  (`BertForSequenceClassification`, 6-layer MiniLM distillation) — this is exactly the shape
  Bumblebee already supports via `Bumblebee.Text.Bert` `:for_sequence_classification`.
  **Loadable today.**

### The Bumblebee cross-encoder PR

`elixir-nx/bumblebee` issue **#251** ("Cross Encoder support") was closed by PR **#444**,
which added a dedicated **`Bumblebee.Text.cross_encoding/3`** serving (in addition to fixing
`Bumblebee.Text.text_classification` to correctly emit `token_type_ids` for sentence-pair
inputs, which previously broke pair-based scoring). **[T1]**
(https://github.com/elixir-nx/bumblebee/issues/251,
https://github.com/elixir-nx/bumblebee/pull/444)

The PR's own example uses `cross-encoder/ms-marco-MiniLM-L-6-v2` as the reference model:

```elixir
Nx.Serving.run(serving, {"query", "document"})
#=> %{score: 8.76}
```

This is strong first-party confirmation that **BERT-family cross-encoders with a
sequence-classification head are the officially supported/tested path** in Bumblebee, and
that anything outside the BERT/RoBERTa/ALBERT/DistilBERT/ModernBERT/MPNet family is
unsupported without upstream work.

## 2. How Arcana does it

Arcana (georgeguimaraes/arcana) documents `cross-encoder/ms-marco-MiniLM-L-6-v2` as its
**default local reranker**, running through Bumblebee with EXLA/EMLX/Torchx as the backend,
structured as an `Nx.Serving` under the app's supervision tree. **[T2]**
(https://arcana.hexdocs.pm/readme.html, https://github.com/georgeguimaraes/arcana)

Arcana reports this reranker improved MRR by +39% and Hit@1 by +62% on its internal
"doctor-who" eval, consistent with the generally cited 10-25% top-k accuracy gain from
adding a cross-encoder stage over bi-encoder retrieval alone. Rerankers in Arcana are a
pluggable behaviour (single callback), so swapping in a different model or an LLM-based
reranker doesn't require touching core infra. I could not find Arcana's actual reranker
source module (README/doc pages only) to see whether it uses `Bumblebee.Text.cross_encoding`
directly or a hand-rolled `Nx.Serving`; given the model choice (`ms-marco-MiniLM-L-6-v2`)
and timing, it's plausible it predates or wraps PR #444's `cross_encoding` helper, but this
is not confirmed — **treat as likely, not verified**.

This nonetheless **proves the BERT-cross-encoder-under-Bumblebee pattern works in
production-style Elixir code**, using exactly the model we're most likely to end up with.

## 3. Code-suitability evidence

This is thin. I found **no CoIR or CodeSearchNet benchmark numbers specifically for
`ms-marco-MiniLM-L-6-v2`** reranking code. `ms-marco-MiniLM` was trained purely on MS MARCO
(natural-language web passage ranking), with no code in its training distribution. General
IR literature and forum consensus:

- Cross-encoders trained on natural-language passage ranking (MS MARCO) tend to transfer
  reasonably to "semi-structured" text but degrade on genuinely different distributions
  (code, tables) because tokenization and relevance signals differ — code identifiers,
  indentation, and cross-file structure aren't well modeled by a QA-style relevance head.
- Jina explicitly markets **jina-reranker-v2** as having "code search capabilities" as a
  named use case **[T3]** (https://jina.ai/news/jina-reranker-v2-for-agentic-rag...), which
  implies its training mix included code pairs — but as established above, it's not loadable
  in Bumblebee regardless.
- No vendor benchmark I found reports bge-reranker or mxbai-rerank numbers on
  CodeSearchNet/CoIR either, despite the CoIR benchmark existing specifically for this gap.

**Honest conclusion:** none of the rerankers loadable in Bumblebee today have published
code-retrieval benchmarks. `ms-marco-MiniLM-L-6-v2` is *not confirmed bad* on code, but
there's no evidence it's good either — it should be treated as "probably acceptable as a
generic lexical/semantic relevance signal over query+chunk text (including docstrings/comments
adjacent to code), but unvalidated for pure-code relevance" until you run an eval against
your own corpus. Given you already have nomic-embed-text-v1.5 doing first-stage retrieval,
consider running a quick offline eval (a few dozen labeled query→chunk pairs) before trusting
MiniLM's scores in production ranking.

## 4. Practical pick

Given the Bumblebee architecture constraint, there are really only **two realistic options**,
and one of them is the one already in wide use:

1. **`cross-encoder/ms-marco-MiniLM-L-6-v2`** (BERT, 6 layers, ~22M params) — loadable today
   via `Bumblebee.Text.cross_encoding`, proven pattern (Arcana default), well-understood
   latency. Max sequence length: **512 tokens** (standard BERT positional limit). Tokenizer
   truncates/concatenates `[CLS] query [SEP] passage [SEP]`, so your effective passage budget
   is `512 - len(query_tokens) - 3`. For code chunks, 512 subword tokens is roughly 300-450
   LOC-ish tokens depending on identifier density — likely **too small for full functions/
   modules** if your chunks are large; you may need to pass a truncated/summarized chunk
   (e.g. first N lines + signature) rather than the full chunk text.
2. **Any other MiniLM/BERT-family cross-encoder checkpoint fine-tuned differently** (e.g. a
   `cross-encoder/ms-marco-MiniLM-L-12-v2` for slightly better quality at ~2x cost, or a
   community BERT-based code-reranker checkpoint if one exists — I did not find one during
   this pass) — same architecture, same Bumblebee support story, just swap the HF repo id.

Everything else (bge-reranker-base/v2-m3, jina-reranker-v2, mxbai-rerank-*) is **blocked**
on either missing XLM-RoBERTa/DeBERTa-v2 architecture support in Bumblebee or on
`trust_remote_code` custom modeling code Bumblebee has no mechanism for. Someone would need
to contribute an `XlmRoberta` (or DeBERTa-v2) architecture module to Bumblebee first.

**Rough CPU latency for 50 pairs, ms-marco-MiniLM-L-6-v2, EXLA on CPU:** one widely cited
figure is ~1.1s per 1000 pairs for this model on CPU **[T3]** (aggregated from search;
unverified against your hardware), which extrapolates to roughly **50-100ms for 50 pairs** —
comfortably inside your 100-300ms budget, assuming batched inference and no cold-start
compilation cost (EXLA JIT warm-up should happen once at boot, not per-request, same as your
embedding serving). Actual numbers will depend heavily on sequence length (truncate long
code chunks to keep this fast) and whether you batch all 50 pairs in one `Nx.Serving` call
(you should — `Bumblebee.Text.cross_encoding` accepts lists of pairs).

## Sources

- **[T1]** [Bumblebee API Reference (v0.7.1)](https://bumblebee.hexdocs.pm/api-reference.html)
- **[T1]** [Cross Encoder support - Issue #251](https://github.com/elixir-nx/bumblebee/issues/251)
- **[T1]** [PR #444 (cross_encoding serving)](https://github.com/elixir-nx/bumblebee/pull/444)
- **[T1]** [BAAI/bge-reranker-v2-m3 (HF model card, XLMRobertaForSequenceClassification)](https://huggingface.co/BAAI/bge-reranker-v2-m3)
- **[T1]** [cross-encoder/ms-marco-MiniLM-L6-v2 (HF)](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L6-v2)
- **[T3]** [vllm-ascend Issue #1960 - XLMRobertaForSequenceClassification not supported](https://github.com/vllm-project/vllm-ascend/issues/1960)
- **[T2]** [Arcana README](https://arcana.hexdocs.pm/readme.html)
- **[T2]** [Arcana GitHub repo](https://github.com/georgeguimaraes/arcana)
- **[T3]** [Jina Reranker v2 announcement (code search claim)](https://jina.ai/news/jina-reranker-v2-for-agentic-rag-ultra-fast-multilingual-function-calling-and-code-search/)
- **[T3]** [mxbai-rerank-base-v1 (PromptLayer summary, DeBERTa-v2 architecture)](https://www.promptlayer.com/models/mxbai-rerank-base-v1)
- **[T3]** [mixedbread-ai/mxbai-rerank GitHub](https://github.com/mixedbread-ai/mxbai-rerank)
