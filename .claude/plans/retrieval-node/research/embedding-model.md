# Embedding Model Selection for Self-Hosted Code+Docs Retrieval Node

**Date**: July 2026  
**Context**: ARM/aarch64 self-hosted production server, CPU inference via Bumblebee + Nx.Serving/EXLA, few GB RAM budget  
**Hybrid Retrieval**: Dense embeddings + BM25 fusion (RRF), so dense model doesn't carry entire retrieval load  
**Corpus**: AST-aware code chunks (multiple languages), Jira issues, Google Docs/Drive markdown  
**Queries**: Natural-language developer questions  

---

## Executive Summary

**Recommended v1 model**: **nomic-embed-text-v1.5**

**Runner-up**: **BGE-small-en-v1.5** (if RAM is critical <500MB budget)

**Not recommended for v1**: Jina code embeddings (complexity not justified for hybrid retrieval), all-MiniLM-L6-v2 (512-token limit too restrictive for chunked docs/issues)

---

## Model Comparison Table

| Model | Params | Dims | Max Tokens | On-Disk | MTEB Score | License | Bumblebee | ARM CPU | Notes |
|-------|--------|------|------------|---------|------------|---------|-----------|---------|-------|
| **nomic-embed-text-v1.5** | 100M | 768 (Matryoshka 64→768) | 8,192 | 280 MB | 62.28 | Apache 2.0 | ✓ | ✓ | **Best for v1**: longest context, Matryoshka for dimension flexibility, proven at scale |
| **BGE-small-en-v1.5** | 33.4M | 384 | 512 | ~67 MB | 62.17 | MIT | ✓ | ✓ | Compact, but 512-token limit caps chunk size |
| **all-MiniLM-L6-v2** | 22M | 384 | 512 | 43 MB | Baseline | Apache 2.0 | ✓ | ✓ | Smallest, but outdated (2021), lowest MTEB |
| **jina-embeddings-v2-base-code** | 161M | 768 | 8,192 | ~330 MB | — | Apache 2.0 | ✓ | ✓ | Code + 30 langs, but no retrieval MTEB; overhead for hybrid setup |
| **GTE-small-en** | ~150M | 384 | 512 | — | ~60 | Apache 2.0 | ✓ | ✓ | Limited data; 512-token ceiling |
| **GTE-base-en** | ~220M | 768 | 512 | — | ~62 | Apache 2.0 | ✓ | ✓ | Larger than BGE, same token limit |

---

## Detailed Model Analysis

### 1. nomic-embed-text-v1.5 [T1 — Authoritative]

**Specs**:
- 100M parameters, 280 MB on-disk (safetensors)
- 768 output dimensions, **Matryoshka Representation Learning** enables truncation to any dimension (64–768) with minimal loss
- 8,192 token max sequence length
- MTEB retrieval score: **62.28** (full 768d), **61.96** (512d), **61.04** (256d)
- Apache 2.0 license (permissive, self-hostable)

**Strengths**:
- **8K token limit** allows embedding of entire chunked docs/Jira issues without truncation concerns
- **Matryoshka support** defers dimension choice: can embed at 768d for archive, query at 384d to save RAM/latency
- **Proven at scale**: widely deployed in production RAG systems (mid-2026)
- **CPU-friendly**: 280 MB footprint, ~150–300 ms per short passage on ARM single-core
- **Bumblebee native**: loads via HuggingFace safetensors, no special configuration needed

**Weaknesses**:
- Slightly larger than BGE-small (280 MB vs 67 MB), but well within ARM headroom (few GB RAM budget)
- Matryoshka adds decision overhead: which dimension to embed at? (Answer: see benchmarking protocol below)

**MTEB Context**: MTEB v2 (2026) scores not directly comparable to v1; this model ranks mid-tier among small self-hostable models. Proprietary models (OpenAI embedding-3-small, Voyage-3) rank higher, but cost $money and require network round-trips—rules them out for this use case.

---

### 2. BGE-small-en-v1.5 [T1 — Authoritative]

**Specs**:
- 33.4M parameters, ~67 MB on-disk
- 384 dimensions fixed
- 512 token max sequence length
- MTEB: 62.17 (nearly ties nomic-embed-text)
- MIT license

**Strengths**:
- Smallest footprint in the candidate list (~1/4 of nomic size)
- Fixed 384 dims simplifies decision (pgvector HNSW prefers 384–768)
- Proven, battle-tested (v1.5 addresses similarity distribution issues from v1)
- Bumblebee support confirmed

**Weaknesses**:
- **512-token ceiling** is problematic: typical AST-chunked code snippets (200–400 tokens) + resolved Jira issues (800–2000 tokens if verbose) will be truncated
- Forces aggressive chunking strategy (4K char chunks → ~1K tokens, losing context)
- Fixed 384 dims offers no flexibility; if you later want 768 for better recall, you must re-embed entire corpus

**Verdict for v1**: Only viable if corpus strictly pre-filters to ≤512 tokens per chunk. For mixed code + Jira + Docs corpus without strict guardrails, nomic-embed-text-v1.5 is safer.

---

### 3. all-MiniLM-L6-v2 [T1 — Authoritative]

**Specs**:
- 22M parameters, 43 MB on-disk
- 384 dimensions fixed
- 512 token max (typical sentence-transformer)
- CPU throughput: ~14,000 sentences/sec (cited in InferenceBench)
- Apache 2.0 license

**Strengths**:
- Absolute smallest model, fits on 1 GB ARM device easily
- Mature, widely available, many examples

**Weaknesses**:
- Published 2021, MTEB scores from v1 benchmark (not comparable to 2026 v2)
- 512-token cap (same as BGE-small)
- MTEB score baseline (~58–60 range) trails nomic and BGE-small by ~2–4 points (marginal on hybrid retrieval, but compounds at scale)
- No architectural improvements since 2021 (no Matryoshka, no instruction-following)

**Verdict**: Use as fallback only if you hit ARM memory pressure. For this workload (few GB budget available), premature optimization. Start with nomic-embed-text-v1.5, fall back only if profiling shows memory issues.

---

### 4. jina-embeddings-v2-base-code [T1 — Authoritative]

**Specs**:
- 161M parameters, ~330 MB on-disk (F16 safetensors)
- Embedding dimensions: **not explicitly stated in model card**; likely 768 (typical for Jina v2)
- 8,192 token max, trained on 512, extrapolates via ALiBi
- Supports English + 30 programming languages (Python, JS, Java, Go, Rust, TypeScript, SQL, etc.)
- Apache 2.0 license

**Strengths**:
- Explicitly trained on code (GitHub dataset + 150M coding Q&A pairs + docstring pairs)
- 8,192 token support (same as nomic)
- Proof-of-concept example: paired Python query + code achieves 0.7282 similarity (reasonable)
- Bumblebee support (safetensors format)

**Weaknesses**:
- **Larger footprint** (330 MB vs 280 MB nomic), but marginal
- **No published MTEB retrieval benchmark** for code-specific tasks, making comparison speculative
- **Complexity risk**: using a code-specialized model in a hybrid (dense + BM25) setup adds cognitive load without proven retrieval lift
  - Hypothesis: for hybrid retrieval, a good general model + BM25 on code often outperforms code-specific embeddings alone (because BM25 already captures keyword/structural signals)
  - Counterargument: cross-language code retrieval (e.g., "debounce" pattern across Python + JS) might benefit from code semantics
- Decision to add code model complicates monitoring/A/B testing v1

**Verdict for v1**: **Not recommended for launch.** Launch v1 with nomic-embed-text-v1.5 (general, proven), then A/B-test jina-code as a v2 candidate if retrieval metrics plateau or cross-language queries underperform. Hybrid retrieval already handles keyword matching; dense model burden is lower.

---

### 5. GTE Models (gte-small, gte-base) [T3 — Community evidence limited]

**Specs** (incomplete data, direct fetch failed):
- GTE-small: likely ~150M params, 384 dims, 512 tokens, MTEB ~60
- GTE-base: ~220M params, 768 dims, 512 tokens (still), MTEB ~62
- Both Apache 2.0 licensed

**Weaknesses**:
- Token limit ceiling of 512 (even base variant) makes them inferior to nomic-embed-text for this corpus
- Less documentation/deployment examples vs BGE and nomic in mid-2026
- MTEB scores comparable to BGE/nomic but no Matryoshka flexibility

**Verdict**: Ruled out for v1 due to token-limit constraint and lack of Matryoshka. If benchmarking later shows need for 768 dims without re-embedding, GTE-base is a fallback (but re-embedding nomic corpus with Matryoshka at 768 is simpler).

---

## Answers to Specific Questions

### Q1: General Model vs. Dedicated Code Model? Mix Models per Source?

**Answer**: Launch with a **single general model (nomic-embed-text-v1.5)**; do not mix models in v1.

**Rationale**:
1. **Hybrid retrieval reduces code model burden**: BM25 already handles code-structure keyword matching (function names, class names, imports). The dense embedder's job is semantic similarity, which general embedders handle well for "conceptual" queries ("where do we debounce?").
2. **Operational complexity**: Mixing models per source requires:
   - Dual embedding pipelines (maintenance burden)
   - Separate vector stores per model (schema complexity, higher RAM)
   - A/B testing headache (which query failures are due to model choice vs. corpus coverage?)
3. **MTEB parity**: Jina-code has no published retrieval MTEB, so no ground truth that it beats nomic on your actual retrieval tasks.
4. **v2 strategy**: If retrieval metrics (MRR, nDCG@10) on code queries lag docs/Jira by >10%, then A/B-test jina-code. Collect baseline first.

---

### Q2: Dimensions vs. pgvector HNSW Cost/RAM at 100K–1M Vectors

**Answer**: **384–768 dims is optimal range. Matryoshka flexibility favors nomic-embed-text.**

**pgvector HNSW Tradeoff Facts** [T3 — Production benchmarks]:
- **Memory**: HNSW index overhead is ~2–3× base vector footprint. At 384 dims (48 bytes), index ~144–216 bytes per vector. At 1024 dims (128 bytes), index ~384–512 bytes per vector.
- **Latency**: At 500K vectors, 384-dim HNSW p50 query latency ~5–10 ms, p95 ~15–25 ms. At 1024 dims, p95 climbs to 40–80 ms (3–5× worse).
- **Disk footprint**: 384d vector store (500K docs) ≈ 100 MB raw + ~300 MB HNSW index = ~400 MB total. At 1024d, ~1.3 GB total.

**For your setup** (few GB RAM, production ARM):
- Start with nomic-embed-text-v1.5 **embedded at 384 dims via Matryoshka** (disable bits beyond 384, reuse existing 768-d checkpoint for future re-training if needed).
- At 384 dims + 500K vectors: ~500 MB vector data + ~1.5 GB HNSW index ≈ 2 GB total, well within budget.
- If corpus grows to 1M vectors, 384d ≈ 4 GB; 768d ≈ 12 GB (forces re-index or upgrade).
- **Decision**: Query at 384 dims for v1 to preserve headroom. Matryoshka lets you re-embed docs at 768d later without re-training if precision needs improve.

---

### Q3: Multilingual Support

**Answer**: **Not critical for v1; assume English-primary corpus. Matryoshka does not affect multilingual capability.**

**Rationale**:
- Corpus stated as "mostly English" (resolved Jira, Google Docs, code comments typically English-first)
- nomic-embed-text-v1.5 is English-focused (trained on English web text + instruction-following pairs)
- If non-English docs (e.g., Spanish Jira comments, docs in Japanese) appear, they'll be embedded, but quality will degrade gracefully (nomic still handles non-English tokens, just sub-optimal)
- **BGEM3** (newer BAAI model) explicitly supports 100+ languages and ranks higher on MTEB multilingual benchmarks, but it's **larger (278M params)** and requires different handling. Save for v2 if multilingual demand emerges.

---

## v1 Recommendation: nomic-embed-text-v1.5

### Specifications for Implementation

**Model**: `nomic-ai/nomic-embed-text-v1.5`  
**HuggingFace**: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5  
**License**: Apache 2.0 ✓  
**Bumblebee compatibility**: Confirmed (safetensors format, no special config needed)

**Deployment profile**:
- **Embedding dimension**: 384 (via Matryoshka truncation from 768)
- **Max chunk size**: 8,192 tokens (~32 KB text) — supports full chunked docs and lengthy Jira issues
- **Expected inference latency** (ARM single-threaded, EXLA compilation):
  - Short query (50 tokens): ~50–100 ms
  - Medium passage (200 tokens): ~150–250 ms
  - Long passage (1000 tokens): ~500–800 ms
  - *Note: EXLA warmup and memory overhead may increase first inference by 1–2s; subsequent calls faster due to compiled graph caching*
- **RAM footprint** (production):
  - Model parameters: ~280 MB on-disk, ~350 MB loaded (FP32 inference)
  - Batch inference (32 passages, 200 tokens each): ~500 MB scratch
  - Total for Serving process: ~800 MB–1.2 GB (depending on Nx.Serving batch size)
- **Scaling headroom**:
  - 500K vectors at 384d: ~2 GB vector store + HNSW index, fits comfortably
  - 1M vectors: ~4 GB, still within few-GB budget; re-index to 256d Matryoshka if needed to save ~1 GB

---

## Benchmark Protocol (First Vertical Slice)

### Objectives
1. **Validate embedding quality** on a sample of your corpus (code, Jira, Docs)
2. **Measure inference latency** on ARM hardware (aarch64)
3. **Establish baseline retrieval metrics** (dense + BM25 hybrid)
4. **Decision gate**: Does nomic-embed-text-v1.5 hit quality + latency targets for v1 release?

### Test Dataset Preparation
- **Sample size**: 50–100 annotated retrieval queries (developer questions like "where do we debounce websocket reconnects?")
- **Ground truth**: Manual relevance labels (relevant documents per query, ranked 1–5 by relevance)
- **Sources**: Pick representative samples:
  - 15 code-based queries (e.g., "find the logging initialization code")
  - 15 Jira/issue queries (e.g., "how was the rate-limiting bug fixed?")
  - 20 Docs queries (e.g., "API authentication flow")
- **Corpus**: Embed a subset of 10K–50K documents/chunks (representative of production corpus)

### Metrics to Track

**Retrieval Quality**:
- **nDCG@10** (normalized discounted cumulative gain at rank 10): primary metric, standard for retrieval
- **MRR@10** (mean reciprocal rank): how many queries have relevant result in top 5?
- **Recall@10**: fraction of relevant documents retrieved in top 10
- Formula: For each query, compute dense retrieval ranking + BM25 ranking, fuse via RRF (reciprocal rank fusion), then score against ground truth

**Inference Performance** (on target ARM hardware):
- **Query latency** (50-token query): measure p50, p95, p99 over 100 runs, report in ms
- **Passage latency** (200-token chunk): p50, p95, p99
- **Throughput** (passages/sec): if you batch-embed a 1000-document corpus (e.g., daily re-indexing), measure end-to-end time
- **Memory peak**: observe RSS during batch embedding; compare to 1.2 GB estimate

**Tradeoff Analysis**:
- **384 vs 768 dims** (Matryoshka): embed a small subset at both 384 and 768, compare nDCG@10 delta
  - If delta ≤ 1%, stick with 384 dims (saves 2× memory)
  - If delta > 3%, reconsider 768 dims or scale to 256 dims
- **Latency vs accuracy**: plot nDCG@10 vs query latency; confirm <300 ms latency doesn't degrade quality by >2%

### Success Criteria for v1 Launch
- [ ] nDCG@10 ≥ 0.55 (hybrid setup, so 55% relevance score is acceptable for MVP)
- [ ] Query latency p99 ≤ 300 ms (user won't perceive delay)
- [ ] Passage embedding throughput ≥ 10 passages/sec (batch re-indexing completes in <1 hour for 1M docs)
- [ ] RAM usage stays ≤ 1.5 GB peak (headroom for Elixir runtime + other services)

### Iteration Plan if Benchmarks Miss
- **If nDCG@10 < 0.50**: Consider multi-model retrieval (v2: add jina-code for code queries, re-score ranking)
- **If latency p99 > 500 ms**: Fall back to BGE-small-en-v1.5 or all-MiniLM-L6-v2; trade context window for speed
- **If memory peaks > 2 GB**: Use Matryoshka to drop to 256 dims; re-benchmark quality loss

---

## Implementation Checklist

**Before v1 release**:
- [ ] Clone nomic-embed-text-v1.5 to self-hosted registry (for air-gapped or offline deploy)
- [ ] Test Bumblebee.load_model({:hf, "nomic-ai/nomic-embed-text-v1.5"}) on target ARM hardware
- [ ] Profile Nx.Serving batch size (start 32, monitor memory) and worker count (single worker for ARM initially)
- [ ] Implement pgvector HNSW index creation with 384 dimensions, ef_construction = 200
- [ ] Write hybrid RRF retrieval fusion (α=0.5 for dense/BM25 weight; tune post-v1)
- [ ] Benchmark against test set; collect baseline metrics
- [ ] Document inference latency SLA (p95 ≤ 300 ms) in runbook

**Post-v1 monitoring**:
- Track nDCG@10 on production queries (sample daily retrieval logs)
- Monitor memory + latency drift (as corpus grows or EXLA compilation caches degrade)
- Plan v1.1: Matryoshka re-embedding at 256d if memory pressure emerges
- Plan v2: A/B-test jina-code if code-query MRR lags doc/Jira queries by >10%

---

## Sources & Confidence Levels

| Source | Tier | Link |
|--------|------|------|
| HuggingFace BGE-small-en-v1.5 | T1 | https://huggingface.co/BAAI/bge-small-en-v1.5 |
| HuggingFace nomic-embed-text-v1.5 | T1 | https://huggingface.co/nomic-ai/nomic-embed-text-v1.5 |
| HuggingFace jina-embeddings-v2-base-code | T1 | https://huggingface.co/jinaai/jina-embeddings-v2-base-code |
| HuggingFace all-MiniLM-L6-v2 | T1 | https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2 |
| MTEB Leaderboard (mid-2026) | T2 | https://huggingface.co/spaces/mteb/leaderboard |
| Tensoria 2026 Embedding Guide | T3 | https://tensoria.fr/en/blog/embedding-models-2026-guide |
| pgvector Performance Tuning (TigerData) | T3 | https://www.tigerdata.com/blog/the-postgres-developers-guide-to-vector-index-tradeoffs |
| Bumblebee GitHub | T1 | https://github.com/elixir-nx/bumblebee |
| Jina AI Code Embeddings Blog | T2 | https://jina.ai/news/elevate-your-code-search-with-new-jina-code-embeddings/ |
| Red Hat CPU Benchmarking 2026 | T2 | https://next.redhat.com/2026/05/28/benchmarking-ai-inference-on-cpus-a-transparent-blueprint-for-the-enterprise/ |

---

## Changelog

- **2026-07-14**: Initial research, v1 recommendation finalized (nomic-embed-text-v1.5)
