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

### Curated knowledge lane

Some knowledge is durable, human/agent-authored context that explains why the
system works a certain way rather than derived collector output: business
context, imported documents, decision records, change intents, and OKF
concepts. `KnowledgeArtifact::CURATED_ARTIFACT_TYPES` is the single canonical
list of these curated artifact types; `KnowledgeArtifact.curated_type?` and
`KnowledgeArtifact#curated?` classify any artifact type against it, and the
`curated` / `derived` scopes filter by it. `Knowledge::Okf::Export` reuses the
same constant rather than duplicating the list.

This curated/derived distinction is surfaced everywhere knowledge is
consumed or reported on, without a separate storage backend or new artifact
schema — Postgres/Qdrant remain the runtime retrieval engine:

- **Search** — `Knowledge::Search` tags every result with `curated: true/false`
  so callers (the search UI, API consumers) can distinguish curated hits from
  derived ones without a second lookup.
- **Browse** — the knowledge browse index groups artifact-type tiles into a
  "Curated Knowledge" section and a "Derived Knowledge" section; the
  per-type browse page badges the type as Curated or Derived.
- **Knowledge map** — `Knowledge::Map::Build` includes `lane_counts`, an
  active/stale artifact-count breakdown by lane, alongside the existing
  per-type `artifact_counts`.
- **Usage stats** — `Knowledge::UsageStats#usage_by_lane` and
  `Knowledge::DashboardStats#usage_by_lane` bucket existing
  `knowledge_usage_stats` rows (already keyed by `artifact_type`) into
  curated/derived totals rather than requiring a new usage-tracking column.
- **Context bundles** — `Knowledge::ContextBundle::Build::SECTION_ORDER`
  places every curated section (business context, imported documents, OKF,
  decisions, change intents) before every derived section (routes, symbols,
  schema, hotspots, stats), so curated knowledge is never pushed out of a
  token-constrained bundle by codebase-derived context.

### OKF bundle export

Paid remains the canonical knowledge store; OKF export (`Knowledge::Okf::Export`)
is an opt-in diagnostic and portability path, not a sync target. A project
member picks curated-only (`okf_concept`, `business_context`,
`reference_document`, `decision_record`, `change_intent`) or additional
derived artifact types (routes, symbols, schema, and similar collector
output), and the service renders each selected active artifact as Markdown
with YAML frontmatter, packaged as a downloadable `.tar.gz`
(`Knowledge::Okf::BundleArchive`, stdlib-only, no new gem dependency).

Frontmatter carries a `paid` block with the artifact's Paid knowledge-base
URI, artifact type, collector type, scope, identifier, source commit SHA,
and timestamps, so an exported file always traces back to the originating
Paid KB record. Body content is taken only from the artifact's active
chunks (preferring a `definition` chunk); artifacts with no active chunks —
i.e. fully redacted — are skipped rather than falling back to raw,
unscrubbed content. `Knowledge::Okf::Frontmatter` is shared between the OKF
collector (parse) and the exporter (render), so every exported file
round-trips through the same parser the collector uses to ingest a bundle.

### Search and retrieval

Exact retrieval uses PostgreSQL identifier matching with trigram fallback.
Semantic retrieval combines PostgreSQL lexical chunk search with Qdrant vector
search when an embedding provider and healthy Qdrant collection are available.
Hybrid search merges both result sets and reranks them with version, activity,
and link signals.

When the vector half of semantic/hybrid search doesn't run to completion —
Qdrant unconfigured or unhealthy, the project has no chunks with an
`embedding_model` recorded yet, the Qdrant collection is missing or empty
(`no_index`, which catches the post-`rebuild_schema!` case where PostgreSQL
chunks still carry an `embedding_model` but the collection was recreated
without re-upserting points), query-embedding generation fails, or the
Qdrant call itself errors — `Knowledge::Search` reports that in `meta`
(`vector_search_status`, `degraded: true`) instead of silently returning
lexical-only results that look identical to a healthy hybrid search. A query
that legitimately has zero vector matches is not degraded; only a vector
search that could not run or complete is.

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

### Knowledge lint and drift checks

`Knowledge::Quality::Lint` adds a read-only "knowledge lint" pass adapted from
OKF validate/lint. It runs a fixed set of `Knowledge::Quality::Checks::*`
checks against a project's artifacts, chunks, links, and usage telemetry and
returns a bounded list of structured findings. Each finding carries a stable
`code` (e.g. `stale_scope_path`, `orphaned_chunk`, `low_usage_type`,
`chunk_missing_embedding`), a severity (`info`, `warning`, `error`), a
`target_type`/`target_id` for traceability, and a short `detail` string.
`embedding_coverage_critical` escalates `chunk_missing_embedding` from a
per-chunk `warning` into a single project-level `error` finding once
embedding coverage across active chunks is at or near zero, so a project
where semantic search has structurally stopped contributing doesn't just
read as one more warning among thousands of identical ones.
The service is read-only — no `Knowledge*` model is mutated — and does not
change `Knowledge::CollectorRunner`, `Knowledge::Search`, or
`Knowledge::ContextBundle::Build` behavior. The report is exposed through a
JSON API endpoint (matching the existing `/api/knowledge/*` namespace) for
agents and CI consumers and through a human-readable project page section so
operators can review findings without writing a script.

## Important Boundaries

- **Not MeiliSearch.** The superseded RDR-018 sketch referenced MeiliSearch for
  full-text search. The shipped implementation uses PostgreSQL trigram and
  `tsvector` search instead, with Qdrant only for vector retrieval.
- **Not Qdrant-as-source-of-truth.** PostgreSQL remains canonical; Qdrant is a
  rebuildable derivative.
- **Not automatic collector mutation.** Knowledge-evolution analysis produces
  pending recommendations for human review; it does not silently add or remove
  collectors.
