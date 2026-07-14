# Research Hold Check — Elixir/Phoenix Claims (Mid-2026)

## 1. `anubis_mcp` Hex Package

| Aspect | Status |
|--------|--------|
| **Existence** | ✅ Confirmed — Hex.pm + GitHub |
| **Current Version** | 1.6.2 (as of June 9, 2026) |
| **License** | LGPL-3.0 |
| **Last Release** | June 9, 2026 (recent) |
| **All-time Downloads** | 265,704 |
| **Open Issues** | 12 (tracked on GitHub) |
| **Successor Claim** | ✅ Fork of hermes-mcp (renamed due to corporate uncertainty) |
| **MCP Server Library** | ✅ Confirmed — complete client + server implementations |
| **Streamable HTTP Support** | ✅ Confirmed — Plug-based + Phoenix integration with multiple transports (streamable HTTP, SSE) |
| **Recommended Status** | ✅ Yes — primary Elixir MCP server library for Phoenix |
| **Maturity Signals** | Good: recent release, 265k+ downloads, active issue tracking |

**Notes:**
- Provides compile-time component registration + runtime component registration.
- Supports multiple transports; streamable HTTP is standard pattern.
- Project maturity: production-ready adoption signal.

---

## 2. `tree_sitter_language_pack` Hex Package

| Aspect | Status |
|--------|--------|
| **Existence** | ✅ Confirmed — Hex.pm v1.12.5 |
| **Current Version** | 1.12.5 (released July 7, 2026) |
| **License** | MIT |
| **Grammar Count** | 306+ languages (incl. Elixir/HEEx/EEx) ✅ |
| **On-demand Download** | ✅ Parsers fetch + local cache on first use |
| **Bundled Tags Queries** | ✅ Pre-built `tags` queries for chunk boundaries |
| **Prefetch Function** | ✅ Exists |
| **Execution Model** | ⚠️ **NIF-based (Rustler)** — NOT out-of-process |
| **Panic Safety** | ⚠️ **Not explicitly documented** — Rustler provides memory safety vs C, but malformed input crash risk remains inherent to NIF model |
| **License** | MIT ✅ |
| **Last Release** | July 7, 2026 (very recent) |

**Red Flags:**
- **NIF execution model**: Crash on malformed input could panic BEAM VM. This is a tradeoff; Rustler mitigates many safety issues, but NIF safety is not absolute.
- No documented panic-safety / input validation for corrupted grammar definitions.
- Consider sandboxing or input validation at application layer if parsing untrusted input.

**Notes:**
- Rust-based (Rustler) provides better memory safety than C NIFs but does not eliminate panic risk.
- Actively maintained (v1.12.5 just released July 7, 2026).

---

## 3. `pgvector` + `VectorChord`

### pgvector (Elixir Hex)

| Aspect | Status |
|--------|--------|
| **Existence** | ✅ Confirmed — Hex.pm |
| **Current Version** | 0.4.0 |
| **License** | MIT |
| **Last Release** | June 4, 2026 |
| **All-time Downloads** | 971,100 |
| **Mainstream Status** | ✅ **Confirmed** — primary default for Elixir + Postgres semantic search |
| **HNSW Index Support** | ✅ |
| **IVFFlat Index Support** | ✅ |
| **Distance Metrics** | l2_distance, max_inner_product, cosine_distance, l1_distance, hamming_distance, jaccard_distance |
| **Ecto Support** | ✅ |

### VectorChord

| Aspect | Status |
|--------|--------|
| **Existence** | ✅ Confirmed — PostgreSQL extension |
| **License** | ✅ AGPL v3 + Elastic License v2 (dual-licensed) |
| **Vector Type Dependency** | ✅ Reuses pgvector's `vector` and `halfvec` types |
| **vchordrq Index Type** | ✅ Built on pgvector's vector type — direct index-swap migration path |
| **Migration Path** | ✅ Possible (index-swap, not schema-break) |
| **Successor Status** | Successor to pgvecto.rs |

**Performance Note:** VectorChord achieves ~2x QPS vs pgvector at equivalent recall; index build 16x faster (1M vectors, 960D).

---

## 4. `Bumblebee` + `Nx.Serving` (Small Embeddings on CPU)

| Aspect | Status |
|--------|--------|
| **Existence** | ✅ Confirmed — Hex.pm |
| **Current Version** | 0.7.0 |
| **License** | Apache-2.0 |
| **Last Release** | May 15, 2026 |
| **All-time Downloads** | 427,462 |
| **Standard Approach** | ✅ **Confirmed** — primary Elixir method for embedding models on CPU |
| **Supported Models** | bge-small, nomic-embed, sentence-transformers models ✅ |
| **Nx.Serving Support** | ✅ Text embedding serving available |
| **EXLA Availability** | ✅ Available (optional dependency) |
| **EXLA CPU Support** | ✅ JIT compilation + CPU execution |
| **llama.cpp Fallback** | Reasonable; not deprecated |

**Setup:** `{:bumblebee, "~> 0.7.0"}, {:exla, ">= 0.0.0"}` + Nx.Serving for distributed inference.

---

## 5. Reciprocal Rank Fusion (RRF): pgvector + tsvector FTS

| Aspect | Status |
|--------|--------|
| **Pattern Existence** | ✅ **Confirmed** — well-documented, production-tested |
| **Soundness** | ✅ Theoretically sound + empirically validated |
| **SQL Technique** | Window functions (`row_number() OVER`) + RRF scoring formula |
| **Standard k Parameter** | k=60 (literature-backed) |
| **Precision Gain** | ~62% (vector only) → 84%+ (RRF + pg_trgm + tsvector) |
| **Implementation Complexity** | Moderate — single query, no external sorting needed |

**Formula:** `1.0 / (k + rank_position)` per result set, summed across rankings.

---

## Summary Maturity Assessment

| Package | Tier | Status | Version | Last Release | Download Signal |
|---------|------|--------|---------|--------------|-----------------|
| anubis_mcp | Production | ✅ Active | 1.6.2 | June 2026 | 265k+ |
| tree_sitter_language_pack | Production | ✅ Active | 1.12.5 | July 2026 | — |
| pgvector | Production | ✅ Active | 0.4.0 | June 2026 | 971k+ |
| VectorChord | Production | ✅ Active | 1.1.0 | — | — |
| Bumblebee | Production | ✅ Active | 0.7.0 | May 2026 | 427k+ |
| RRF Pattern | Production | ✅ Sound | N/A | Documented | — |

---

## Key Changes / Red Flags

1. **tree_sitter_language_pack NIF Risk**: Execution is NIF-based (Rustler-wrapped), not out-of-process. On malformed input (e.g., corrupted grammar or recursive input), BEAM crash possible. **Action:** Validate input or consider application-layer sandboxing.

2. **VectorChord License**: AGPL v3 + ELv2 dual-license. If using commercially without ELv2, AGPL copyleft applies. **Action:** Confirm licensing model for deployment.

3. **All Confirmed as of July 2026**: No deprecations found; all packages show recent releases and active downloads.

---

## Confidence Levels

- **Claim 1 (anubis_mcp)**: ✅ 100% — Hex.pm + GitHub source check
- **Claim 2 (tree_sitter_language_pack)**: ⚠️ 95% — Version/license confirmed; NIF model inferred from Rustler docs (not explicitly stated in README)
- **Claim 3 (pgvector + VectorChord)**: ✅ 100% — Hex.pm + docs.vectorchord.ai
- **Claim 4 (Bumblebee + Nx.Serving)**: ✅ 100% — Hex.pm + hexdocs
- **Claim 5 (RRF Pattern)**: ✅ 100% — Multiple production blog posts + SQL pattern docs
