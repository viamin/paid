# RDR-021: Knowledge Base Architecture

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-03-28
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #267 (Knowledge Base Architecture Docs), #66 (Semantic data investigation)
- **Related RDRs**: [RDR-018](RDR-018-semantic-code-search.md) (Semantic Code Search)
- **Note**: The #267 implementation plan originally referenced this as RDR-019. It was renumbered to RDR-021 because RDR-019 was already assigned to Remote Container Execution.
- **Related Tests**: `spec/services/knowledge/`, `spec/models/knowledge_*.rb`

## Problem Statement

Paid agents start every run with no knowledge of the codebase they are working on. They re-discover project structure, conventions, and patterns from scratch — wasting tokens and producing lower-quality output. The knowledge base provides persistent, versioned, semantic understanding of project codebases.

Key requirements:

- **Versioned knowledge** — track what was known at each commit
- **Multi-modal collection** — extract routes, symbols, dependencies, churn, config, and AST-level structures
- **Semantic retrieval** — support both exact lookup and conceptual queries
- **Provenance** — full audit trail from query result back to collector run, commit SHA, and tool version
- **Redaction** — ability to remove sensitive content without breaking the knowledge graph
- **Project isolation** — no cross-project data leakage

## Context

### Background

RDR-018 investigated semantic code search options and recommended Qdrant for vector search with Ruby-native clients. The knowledge base builds on that foundation, adding a structured collector framework, versioned storage in PostgreSQL, and a hybrid search layer.

The [knowledge base implementation plan](../knowledge-base-issues.md) defined 12 issues covering the full pipeline from infrastructure to agent integration.

### Technical Environment

- Rails 8 with PostgreSQL (canonical data store)
- Qdrant v1.13.2 (vector index, Docker-deployed)
- OpenAI text-embedding-3-large (3,072-dimensional embeddings)
- GoodJob for background processing
- Docker-based agent containers with git worktrees

## Proposed Solution

### Architecture: PostgreSQL + Qdrant Dual Store

PostgreSQL serves as the canonical source of truth for all knowledge data. Qdrant is a derived vector index used exclusively for semantic search. This separation means:

- Knowledge survives Qdrant outages or data loss (rebuild from PostgreSQL)
- ACID transactions protect knowledge mutations
- Qdrant provides purpose-built vector search without burdening PostgreSQL

### Data Model

Six tables form the knowledge schema:

**`project_versions`** — Commit-SHA-keyed snapshots. Each collection run targets a specific version, creating a point-in-time record of what was analyzed.

**`collector_runs`** — One row per (version, collector_type) pair. Tracks status, duration, artifact count, tool version, and error details. Unique constraint prevents duplicate runs.

**`knowledge_artifacts`** — File-level or logical groupings produced by collectors. Keyed by content hash for deduplication. Support `active`, `stale`, and `deleted` statuses.

**`knowledge_chunks`** — Embeddable text units with UUID primary keys (used directly as Qdrant point IDs). Support `active`, `stale`, `deleted`, and `redacted` statuses. Include `content_tsvector` for PostgreSQL full-text search.

**`knowledge_links`** — Typed directed edges between chunks (calls, implements, tests, relates_to, depends_on, supersedes). Weighted for relevance ranking.

**`knowledge_audit_events`** — Append-only audit log with BRIN index on `created_at` for efficient time-range queries.

### Collector Framework

The collector framework uses a registry pattern. `CollectorRunner` orchestrates registered collectors in sequence, storing results via `ArtifactStore`.

Seven collectors are implemented:

1. **RoutesCollector** — HTTP endpoint index
2. **SymbolIndexCollector** — Functions, classes, constants
3. **DependencyCollector** — Package manifests
4. **LanguageStatsCollector** — Lines of code, language distribution
5. **ChurnHotspotCollector** — Git churn analysis
6. **ConfigKeyCollector** — Configuration keys
7. **TreeSitterCollector** — Generic AST extraction

Each collector implements a `collect()` method returning artifact hashes. The runner handles idempotency, stale-marking, and audit logging.

### Embedding Pipeline

Chunks needing embeddings (`active` status, `embedding_model` nil) are processed by `Knowledge::Embeddings::Pipeline`:

1. Batch chunks from PostgreSQL
2. Generate embeddings via OpenAI text-embedding-3-large
3. Update chunk records with embedding model
4. Upsert points to Qdrant via `PointSync`
5. Record audit events

### Hybrid Search

`Knowledge::Search` merges three search strategies:

- **Exact**: Trigram fuzzy matching on identifiers (pg_trgm GIN index)
- **Semantic**: Qdrant vector similarity with cosine distance
- **Hybrid**: Combine both with `Reranker` scoring (default mode)

## Decision Rationale

### Why Qdrant over pgvector?

pgvector would avoid additional infrastructure but is a general-purpose extension, not a specialized vector database. Qdrant provides:

- Purpose-built vector indexing (HNSW) with better recall at scale
- Payload filtering without separate queries
- Collection-level isolation (one per project)
- Dedicated resource management independent of PostgreSQL load

Building on Qdrant from the start avoids a future migration from pgvector. See RDR-018 for the full evaluation.

### Why PostgreSQL as canonical store?

Qdrant is optimized for vector search, not relational queries, transactions, or complex joins. PostgreSQL provides:

- ACID transactions for knowledge mutations
- Foreign key constraints maintaining referential integrity
- Full-text search via tsvector (complementing Qdrant)
- Familiar querying for operational tasks and debugging
- Backup/restore with standard PostgreSQL tooling

If Qdrant data is lost, the full vector index can be rebuilt from PostgreSQL.

### Why redaction-first?

Codebases may contain secrets, credentials, or sensitive business logic that should not persist in the knowledge base. The `redacted` status on chunks allows:

- Immediate removal from both PostgreSQL content and Qdrant vectors
- Preservation of the knowledge graph structure (links remain, content is cleared)
- Audit trail of what was redacted and when

### Why UUID primary keys for chunks?

Chunk UUIDs serve dual purpose:

- PostgreSQL primary key
- Qdrant point ID

This eliminates the need for a separate mapping table and makes point operations (upsert, delete) straightforward. Other tables use standard bigint keys since they are not synced to Qdrant.

### Why content-hash deduplication?

Collectors may produce identical artifacts across runs (e.g., unchanged files). SHA-256 content hashing enables:

- Skip re-processing unchanged content
- Detect actual changes vs. cosmetic differences
- Efficient incremental updates

## Alternatives Considered

### Alternative 1: pgvector Only

**Description**: Use PostgreSQL's pgvector extension for all vector operations.

**Reason for rejection**: Transitional technology. Would require migration to dedicated vector DB as scale increases. Better to build on target architecture from the start. See RDR-018.

### Alternative 2: Qdrant as Primary Store

**Description**: Store knowledge directly in Qdrant, skip PostgreSQL.

**Reason for rejection**: Qdrant lacks transactions, complex queries, and referential integrity. Operational tooling (backup, debugging, reporting) is weaker. PostgreSQL provides a reliable foundation that Qdrant complements.

### Alternative 3: Single Monolithic Indexer

**Description**: One service that analyzes everything about a codebase in a single pass.

**Reason for rejection**: Harder to extend, test, and debug. The collector registry pattern allows adding new analysis types independently. Individual collectors can fail without blocking others.

## Trade-offs and Consequences

### Positive Consequences

- Agents receive relevant codebase context from their first run on a project
- Knowledge persists across agent runs (institutional memory)
- Full provenance chain from search result to commit SHA
- Extensible collector framework for new analysis types
- Redaction support for sensitive content

### Negative Consequences

- Additional infrastructure (Qdrant) to deploy and maintain
- Embedding API costs (mitigated by content-hash deduplication and incremental updates)
- Index staleness between collection runs (mitigated by triggering collection on relevant events)
- Storage growth over time (mitigated by stale-marking and retention policies)

### Risks and Mitigations

- **Risk**: Qdrant availability affects search quality
  **Mitigation**: Exact search falls back to PostgreSQL trigram matching. Semantic search degrades gracefully.

- **Risk**: Embedding costs scale with codebase size
  **Mitigation**: Content-hash deduplication, incremental updates, batch processing. Monitor via audit events.

- **Risk**: Stale knowledge misleads agents
  **Mitigation**: Version tracking, stale marking, re-collection on git push. See [runbook](../runbooks/knowledge-base.md).

## Implementation Plan

Implementation followed the [knowledge base issues plan](../knowledge-base-issues.md):

1. Qdrant infrastructure (Docker, client wrapper, health check)
2. PostgreSQL schema (6 tables, 11 migrations)
3. Qdrant collection management (create, upsert, delete, rebuild)
4. Collector framework (runner, artifact store, base collector)
5. Collector implementations (7 types)
6. Embedding pipeline (OpenAI integration, Qdrant sync)
7. Search and retrieval API (exact, semantic, hybrid)
8. Audit and provenance tracking

### Key Files

- `app/services/qdrant_client.rb` — Qdrant connection wrapper
- `app/services/knowledge/collector_runner.rb` — Collection orchestration
- `app/services/knowledge/artifact_store.rb` — Idempotent storage
- `app/services/knowledge/base_collector.rb` — Collector interface
- `app/services/knowledge/collectors/` — 7 collector implementations
- `app/services/knowledge/qdrant/` — Collection and point management
- `app/services/knowledge/embeddings/` — Embedding generation
- `app/services/knowledge/search.rb` — Unified search service
- `app/services/knowledge/provenance/audit_log.rb` — Audit logging

## Validation

### Testing Approach

- Unit tests for each collector, service, and model
- Integration tests for the full collect → store → embed → search pipeline
- Search accuracy benchmarks with representative queries

### Key Test Scenarios

1. Collector produces artifacts → stored in PostgreSQL with correct provenance
2. Re-running collector for unchanged content → no duplicate artifacts
3. Embedding pipeline processes chunks → vectors in Qdrant with matching UUIDs
4. Hybrid search returns relevant results combining exact and semantic matches
5. Qdrant outage → exact search still works via PostgreSQL

## References

- [RDR-018: Semantic Code Search](RDR-018-semantic-code-search.md)
- [Knowledge Base Implementation Plan](../knowledge-base-issues.md)
- [KNOWLEDGE_BASE.md](../KNOWLEDGE_BASE.md) — Architecture overview
- [Operational Runbook](../runbooks/knowledge-base.md)
- [Qdrant Documentation](https://qdrant.tech/documentation/)
