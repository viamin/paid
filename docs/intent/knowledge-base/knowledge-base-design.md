---
parent: PAID
prefix: KNOWLEDGE
---

# Low-Level Design: Knowledge Base

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the shipped knowledge-base, semantic-search, redaction, and
> knowledge-evolution behavior described across RDR-018, RDR-021, and RDR-027.

## Purpose

Paid now ships the knowledge system that earlier brownfield docs still
described as planned:

- PostgreSQL as the canonical store for project versions, collector runs,
  artifacts, chunks, links, and audit events
- Qdrant as a derived vector index for semantic retrieval
- PostgreSQL trigram and `tsvector` search for exact and lexical retrieval
- hybrid search and context-bundle assembly for prompt building
- redaction before embedding plus retroactive scrub/re-embed workflows
- per-run usage attribution and opt-in knowledge-evolution recommendations

This segment captures the intentional implementation so future work traces to
the system that actually shipped.

## Shipped Behavior

### Canonical knowledge storage

Collector runs are versioned by project commit and write artifact/chunk/link
state into PostgreSQL. Full collection runs stale older active artifacts so the
knowledge base tracks what was known for each commit while still surfacing the
latest active view.

### Derived vector indexing

Embeddings are generated for active chunks that still need vectors, then synced
into Qdrant using the chunk UUID as the point ID. Qdrant is intentionally a
derived index: vector payloads exclude chunk content, and semantic retrieval can
be rebuilt from PostgreSQL plus a re-embedding pass.

The embedding model and its vector dimensions are user-configurable per
`user_settings` (`kb_embedding_model`, `kb_embedding_dimensions`); the legacy
`text-embedding-3-large` / 3072 pair is the bundled default so existing
knowledge bases keep working. The `Knowledge::Embeddings::ProxyGenerator` reads
the configured values from the project's owner settings and threads them through
the secrets-proxy-backed container, which already accepted arbitrary provider /
model / dimensions via env vars. The runner-selection warning that fires when
multiple embedding runners are configured references the configured model and
dimensions rather than a hardcoded constant. Changing the model or dimensions
on a populated knowledge base invalidates the Qdrant index and requires a
re-embed; the embedding pipeline still records the new model id on each chunk
as it is re-embedded.

### Search and retrieval

Exact retrieval uses PostgreSQL identifier matching with trigram fallback.
Semantic retrieval combines PostgreSQL lexical chunk search with Qdrant vector
search when an embedding provider and healthy Qdrant collection are available.
Hybrid search merges both result sets and reranks them with version, activity,
and link signals.

### Prompt context and attribution

Prompt-building flows use two retrieval surfaces:

- `Knowledge::ContextBundle::Build` for curated, token-budgeted context
- `Knowledge::Search` for direct search results

When an `agent_run_id` is provided, both surfaces record per-artifact-type
usage in `knowledge_usage_stats`, which powers downstream effectiveness and
evolution analysis.

### Redaction and re-embedding

Chunks are scanned for sensitive content before embedding. Fully redacted chunks
are marked `redacted` and excluded from embedding; partially redacted chunks are
cleaned and remain searchable. For already-indexed data, retroactive scrub and
re-embed workflows update PostgreSQL content and Qdrant state without losing
the surrounding knowledge graph.

### Knowledge evolution

Projects can opt into knowledge evolution. The workflow samples
`enhance_issue` outcomes, combines them with usage stats, asks an LLM for gap
analysis, and persists pending `KnowledgeRecommendation` records while
dismissing no-longer-flagged pending recommendations.

## Important Boundaries

- **Not MeiliSearch.** The superseded RDR-018 sketch referenced MeiliSearch for
  full-text search. The shipped implementation uses PostgreSQL trigram and
  `tsvector` search instead, with Qdrant only for vector retrieval.
- **Not Qdrant-as-source-of-truth.** PostgreSQL remains canonical; Qdrant is a
  rebuildable derivative.
- **Not automatic collector mutation.** Knowledge-evolution analysis produces
  pending recommendations for human review; it does not silently add or remove
  collectors.
