# Knowledge Base Architecture

## Overview

The knowledge base provides Paid agents with persistent, semantic understanding of the codebases they work on. Instead of rediscovering project structure, patterns, and conventions from scratch on every run, agents query indexed knowledge — architecture, symbols, dependencies, and relationships — and receive relevant context in their prompts.

The system follows a four-stage pipeline: **Collect → Store → Embed → Retrieve**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         KNOWLEDGE BASE PIPELINE                              │
│                                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐  │
│  │   COLLECT    │──▶│    STORE     │──▶│    EMBED     │──▶│   RETRIEVE   │  │
│  │              │   │              │   │              │   │              │  │
│  │  Collectors  │   │  PostgreSQL  │   │  OpenAI API  │   │  Hybrid      │  │
│  │  analyze     │   │  (canonical  │   │  generates   │   │  search:     │  │
│  │  codebase    │   │   source of  │   │  vectors     │   │  exact +     │  │
│  │              │   │   truth)     │   │              │   │  semantic    │  │
│  └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘  │
│         │                  │                  │                  │            │
│         ▼                  ▼                  ▼                  ▼            │
│    7 collector        Artifacts,         Qdrant vector      Agent prompts    │
│    types              Chunks, Links      index               enriched with   │
│                                                              codebase        │
│                                                              context         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Data Model

The knowledge base uses six PostgreSQL tables with Qdrant as a derived vector index.

### Entity Relationships

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      KNOWLEDGE BASE ENTITIES                                 │
│                                                                              │
│  ┌──────────┐      ┌──────────────┐      ┌────────────────┐                 │
│  │ Project  │──────│ ProjectVersion│──────│  CollectorRun  │                 │
│  └──────────┘      └──────────────┘      └────────────────┘                 │
│                                                  │                           │
│                                                  ▼                           │
│                                          ┌────────────────┐                 │
│                                          │ Knowledge      │                 │
│                                          │ Artifact       │                 │
│                                          └────────────────┘                 │
│                                                  │                           │
│                                                  ▼                           │
│                          ┌───────────────────────────────────────┐           │
│                          │         KnowledgeChunk (UUID PK)      │           │
│                          │                                       │           │
│                          │  ┌─────────────┐   ┌──────────────┐  │           │
│                          │  │ outgoing    │   │  incoming    │  │           │
│                          │  │ links       │   │  links       │  │           │
│                          │  └──────┬──────┘   └──────┬───────┘  │           │
│                          │         │                 │           │           │
│                          │         ▼                 ▼           │           │
│                          │     ┌─────────────────────────┐      │           │
│                          │     │     KnowledgeLink       │      │           │
│                          │     └─────────────────────────┘      │           │
│                          └───────────────────────────────────────┘           │
│                                                                              │
│  ┌──────────────────┐                                                       │
│  │ KnowledgeAudit   │  (provenance tracking for all mutations)              │
│  │ Event            │                                                       │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Tables

| Table | Purpose | Primary Key |
|-------|---------|-------------|
| `project_versions` | Commit-SHA-keyed snapshots of a project | bigint |
| `collector_runs` | Provenance tracking per collector execution | bigint |
| `knowledge_artifacts` | File-level or logical code groupings | bigint |
| `knowledge_chunks` | Embeddable text units (synced to Qdrant) | UUID |
| `knowledge_links` | Typed edges between chunks (calls, implements, tests, etc.) | bigint |
| `knowledge_audit_events` | Audit trail for all knowledge mutations | bigint |

See [DATA_MODEL.md](DATA_MODEL.md) for full schema definitions.

## Collector Framework

Collectors are the data ingestion layer. Each collector analyzes one aspect of a codebase and produces artifacts with embedded chunks.

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    CollectorRunner                             │
│                                                               │
│  1. Resolve/create ProjectVersion (commit SHA)                │
│  2. Run registered collectors in order                        │
│  3. Store artifacts via ArtifactStore                         │
│  4. Mark stale artifacts from older versions                  │
│  5. Emit audit events                                         │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│  BaseCollector (abstract)                                     │
│                                                               │
│  Interface: collect() → Array<Hash>                           │
│    { artifact_type:, scope_path:, identifier:,                │
│      content:, chunks: [...] }                                │
│                                                               │
│  Utilities: run_command, read_repo_file, repo_file_exists?    │
└──────────────────────────────────────────────────────────────┘
```

### Registered Collectors

| Collector | Type | Description |
|-----------|------|-------------|
| `RoutesCollector` | `routes` | Rails/HTTP endpoint index |
| `SymbolIndexCollector` | `symbol_index` | Language symbols (functions, classes, constants) |
| `DependencyCollector` | `dependency` | Package/gem dependency manifest |
| `LanguageStatsCollector` | `language_stat` | Code statistics (lines, languages) |
| `ChurnHotspotCollector` | `churn_hotspot` | Git churn analysis for change-heavy files |
| `ConfigKeyCollector` | `config_key` | Configuration keys and constants |
| `TreeSitterCollector` | `tree_sitter` | Generic AST-based extraction |

### Idempotency

- **Content-hash deduplication**: Artifacts are keyed by `(collector_run_id, content_hash)`. Re-running a collector for the same content is a no-op.
- **Stale marking**: When all collectors succeed for a new version, artifacts from older versions are marked `stale` (not deleted).
- **Unique collector per version**: `(project_version_id, collector_type)` is unique — a collector runs at most once per version.

### Adding a New Collector

1. Create a class inheriting from `Knowledge::BaseCollector`
2. Implement `collect()` returning an array of artifact hashes
3. Register with `Knowledge::CollectorRunner.register(:type, MyCollector)`
4. The runner picks it up automatically on the next collection cycle

## Embedding Pipeline

The embedding pipeline generates vector representations of knowledge chunks for semantic search.

### Flow

```
KnowledgeChunk (status: active, embedding_model: nil)
    │
    ▼
Knowledge::Embeddings::Pipeline
    │
    ▼
Knowledge::Embeddings::Generate
    │  Calls OpenAI text-embedding-3-large API
    │  3,072-dimensional vectors
    ▼
KnowledgeChunk (embedding_model: "text-embedding-3-large")
    │
    ▼
Knowledge::Qdrant::PointSync.upsert_chunk!
    │  UUID chunk ID = Qdrant point ID
    ▼
Qdrant collection: project_{project_id}
```

### Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `QDRANT_URL` | `http://localhost:6333` | Qdrant REST endpoint (use `http://qdrant:6333` when running via Docker Compose) |
| `QDRANT_API_KEY` | (none) | Optional API key |
| `EMBEDDING_DIMENSIONS` | `3072` | Vector dimensions (text-embedding-3-large) |

### Qdrant Collection Structure

- **Naming**: `project_{project.id}` — one collection per project
- **Distance metric**: Cosine similarity
- **Payload indexes**: `project_version_id`, `artifact_type`, `status`
- **Payload fields**: `project_id`, `project_version_id`, `artifact_type`, `scope_tags`, `status`, `created_at`

## Retrieval Modes

The search layer (`Knowledge::Search`) supports three modes:

### Exact Search

Trigram-based fuzzy matching on the `identifier` column of `knowledge_artifacts`. Uses the `pg_trgm` extension with a GIN index.

**Best for**: Known symbol names, file paths, exact identifiers.

### Semantic Search

Vector similarity search via Qdrant. The query text is embedded using the same model (text-embedding-3-large), then matched against stored chunk vectors.

**Best for**: Conceptual queries ("how does authentication work?"), finding related code.

### Hybrid Search (Default)

Combines exact and semantic results with reranking (`Knowledge::Search::Reranker`). Results appearing in both sets receive a boosted score.

**Best for**: General-purpose queries where both exact matches and semantic relevance matter.

### Search API

```
GET /api/knowledge/search
  ?project_id=123
  &q=authentication middleware
  &mode=hybrid          # exact | semantic | hybrid
  &type=symbol          # optional artifact_type filter (e.g., symbol, route)
  &version=1            # optional knowledge artifact version filter
  &limit=20             # max 100
```

Returns:

```json
{
  "results": [...],
  "meta": {
    "took_ms": 42,
    "mode": "hybrid",
    "total": 20,
    "exact_count": 5,
    "semantic_count": 15
  }
}
```

### Full-Text Search

PostgreSQL `tsvector` columns on `knowledge_chunks` provide traditional full-text search with ranking. This complements the trigram-based exact search on identifiers.

## Infrastructure

### Services

```yaml
# docker-compose.yml (excerpt)
qdrant:
  image: qdrant/qdrant:v1.13.2
  ports:
    - "6333:6333"   # HTTP/REST API (default). gRPC (6334) is optional and not exposed by default.
    # To expose gRPC, also publish: "6334:6334"
  volumes:
    - qdrant-data:/qdrant/storage
  networks:
    - paid_internal
```

### Key Services

| Service | Path | Responsibility |
|---------|------|----------------|
| `QdrantClient` | `app/services/qdrant_client.rb` | Connection wrapper with health check |
| `Knowledge::Qdrant::CollectionManager` | `app/services/knowledge/qdrant/collection_manager.rb` | Create/drop/rebuild collections |
| `Knowledge::Qdrant::PointSync` | `app/services/knowledge/qdrant/point_sync.rb` | Upsert/delete points |
| `Knowledge::CollectorRunner` | `app/services/knowledge/collector_runner.rb` | Orchestrate collection pipeline |
| `Knowledge::ArtifactStore` | `app/services/knowledge/artifact_store.rb` | Idempotent artifact storage |
| `Knowledge::Embeddings::Pipeline` | `app/services/knowledge/embeddings/pipeline.rb` | Embedding generation workflow |
| `Knowledge::Search` | `app/services/knowledge/search.rb` | Unified search interface |
| `Knowledge::Provenance::AuditLog` | `app/services/knowledge/provenance/audit_log.rb` | Audit event recording |

### Background Jobs

| Job | Queue | Responsibility |
|-----|-------|----------------|
| `RunCollectorsJob` | default | Trigger collection for a project |
| `QdrantCollectionCleanupJob` | default | Clean up Qdrant on project deletion |
| `KnowledgeAuditRetentionJob` | maintenance | Prune old audit events |

## Design Principles

1. **PostgreSQL is the source of truth** — Qdrant is a derived index. If Qdrant data is lost, it can be rebuilt from PostgreSQL.
2. **Redaction-first** — Chunks support a `redacted` status as a logical flag for excluding sensitive content from processing and search. A future workflow will drive physical removal from PostgreSQL and Qdrant; the flag alone does not automatically scrub stored content or vectors.
3. **Project isolation** — Each project has its own Qdrant collection. No cross-project data leakage.
4. **Idempotent operations** — Collection, storage, and embedding are all safe to retry.
5. **Provenance tracking** — Every mutation is recorded in `knowledge_audit_events` with actor, target, and event-specific details.

## Related Documents

- [RDR-018: Semantic Code Search](rdrs/RDR-018-semantic-code-search.md) — Original investigation and technology selection
- [RDR-021: Knowledge Base Architecture](rdrs/RDR-021-knowledge-base.md) — Formal architectural decision record
- [Operational Runbook](runbooks/knowledge-base.md) — Health checks, rebuild, troubleshooting
- [DATA_MODEL.md](DATA_MODEL.md) — Full database schema
- [Knowledge Base Implementation Plan](knowledge-base-issues.md) — Issue breakdown
