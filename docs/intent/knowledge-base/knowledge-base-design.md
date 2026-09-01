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

### OKF bundle indexing

Projects that already maintain an OKF-style bundle — repo-local Markdown
files with YAML frontmatter under a conventional `.okf/` root or an
explicitly configured path (`options[:okf_paths]`) — get that bundle
indexed as curated knowledge. The optional collector (`okf` collector
type) skips cleanly when no bundle is present, so repositories without
OKF bundles are unaffected. Adopting OKF is never required.

Each valid concept file becomes a distinct curated artifact type
(`okf_concept`) so curated bundle knowledge stays separate from derived
collector output. Artifact metadata carries the source path, concept
type, title, tags, and last-commit metadata for the file; the Markdown
body is preserved verbatim as the artifact content and as curated
definition chunks.

Invalid bundle files (malformed frontmatter YAML, non-mapping
frontmatter, missing frontmatter, empty body, oversized files) are
recorded as findings in the collector run metadata rather than failing
the collector run, and every other collector is unaffected. Valid files
in the same bundle are still indexed.

Context-bundle assembly includes active `okf_concept` artifacts under an
explicit "Curated Knowledge (OKF bundle)" section.

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

### Progressive-disclosure knowledge map

`Knowledge::Map::Build` gives agents and humans a compact orientation view of
a project's knowledge base before they run search: active/stale artifact
counts by type, top scope directories, per-collector freshness (latest run
status against the most recently indexed commit), business-context and
imported-document presence, and inferred collector coverage gaps (never run,
failed, or stale). Output is bounded (top-N scopes/documents, no chunk
bodies) so it stays cheap to fetch repeatedly. It is exposed as a
user-authenticated API endpoint, a container-authenticated proxy endpoint for
agent tool use, and a section on the human knowledge browse page. It does not
change `Knowledge::Search` or `Knowledge::ContextBundle::Build` behavior.

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
