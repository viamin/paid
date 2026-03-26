# Knowledge Base Implementation — GitHub Issue Collection

This document defines the implementation plan for Paid's versioned, provenance-rich knowledge base. It uses PostgreSQL as the canonical source-of-truth and Qdrant as the vector index for semantic retrieval.

**Dependencies between issues are noted inline.** Issues are ordered roughly by implementation sequence.

---

## Issue 1: Qdrant Infrastructure — Docker, Config, Client Wrapper, Health Check

**Labels:** `knowledge`, `qdrant`, `infra`

### Background / Why

The knowledge base requires Qdrant as the vector index for semantic retrieval. Before any collector or embedding work can begin, we need Qdrant running in development, a Ruby client wrapper with connection pooling and retries, and health-check integration so the dashboard and `bin/ci` can verify the service is available.

### Scope

**In scope:**

- Add Qdrant to `docker-compose.yml` on the `paid_internal` network
- Add `qdrant-ruby` gem to `Gemfile`
- Create `QdrantClient` wrapper service (`app/services/qdrant_client.rb`) with configurable URL, API key, timeouts, and retry logic
- Create `config/initializers/qdrant.rb` to set defaults from ENV
- Add a `/up` -style health check endpoint or extend the existing one to include Qdrant status
- Add Qdrant connection verification to `bin/setup`

**Out of scope:**

- Collection creation (Issue 3)
- Embedding generation (Issue 8)
- Production deployment topology (separate ops issue)

### Proposed Design

**docker-compose.yml addition:**

```yaml
qdrant:
  image: qdrant/qdrant:v1.13.2
  ports:
    - "6333:6333"   # REST
    - "6334:6334"   # gRPC
  volumes:
    - qdrant_data:/qdrant/storage
  networks:
    - paid_internal
  environment:
    QDRANT__SERVICE__API_KEY: ${QDRANT_API_KEY:-}
```

**QdrantClient wrapper (`app/services/qdrant_client.rb`):**

```ruby
class QdrantClient
  DEFAULT_URL = "http://qdrant:6333"
  MAX_RETRIES = 3

  def self.instance
    @instance ||= new(
      url: ENV.fetch("QDRANT_URL", DEFAULT_URL),
      api_key: ENV["QDRANT_API_KEY"]
    )
  end

  def initialize(url:, api_key: nil)
    @client = Qdrant::Client.new(url: url, api_key: api_key)
  end

  delegate :collections, :points, to: :client

  def healthy?
    client.collections.list
    true
  rescue StandardError
    false
  end

  private

  attr_reader :client
end
```

### Implementation Tasks

- [ ] Add `qdrant-ruby` to `Gemfile`; run `bundle install`
- [ ] Add Qdrant service to `docker-compose.yml` on `paid_internal` network
- [ ] Add `qdrant_data` volume to `docker-compose.yml`
- [ ] Create `config/initializers/qdrant.rb` (reads `QDRANT_URL`, `QDRANT_API_KEY` from ENV)
- [ ] Create `app/services/qdrant_client.rb` singleton wrapper
- [ ] Extend Rails health check or add `Knowledge::HealthCheck` service
- [ ] Add Qdrant connectivity check to `bin/setup`
- [ ] Write specs for `QdrantClient` (mock `Qdrant::Client`)

### Acceptance Criteria

- [ ] `bin/dev` starts Qdrant alongside other services
- [ ] `QdrantClient.instance.healthy?` returns `true` when Qdrant is running
- [ ] Health check endpoint reports Qdrant status
- [ ] `bin/rspec` passes with new specs
- [ ] No API keys hardcoded; all via ENV

### Notes / Risks

- Qdrant runs on `paid_internal` — agent containers on `paid_agent` cannot reach it directly. This is intentional; all vector operations happen server-side.
- The `qdrant-ruby` gem uses REST. gRPC is exposed for future perf optimization but not required now.

---

## Issue 2: PostgreSQL Schema — Knowledge Objects, Versioning, Provenance

**Labels:** `knowledge`, `security`

### Background / Why

PostgreSQL is the canonical source-of-truth for all knowledge: artifacts, chunks, provenance, graph edges, and decision records. This schema must support version-anchored knowledge (tied to commit SHAs via `ProjectVersion`), provenance tracking (which collector produced what, when), and staleness detection.

### Scope

**In scope:**

- Migration: `project_versions` table (commit SHA keyed)
- Migration: `collector_runs` table (provenance: who ran what, when, duration, status)
- Migration: `knowledge_artifacts` table (file-level or logical groupings)
- Migration: `knowledge_chunks` table (embeddable text units with stable UUIDs)
- Migration: `knowledge_links` table (graph edges between chunks/artifacts)
- Appropriate indexes, foreign keys, and constraints
- ActiveRecord models with associations and validations

**Out of scope:**

- Decision records (Issue 12)
- Qdrant collection creation (Issue 3)
- Actual collector implementations (Issues 6, 7)

### Proposed Design

**`project_versions`**

```
id              bigint PK
project_id      bigint FK → projects (NOT NULL)
commit_sha      string(40) NOT NULL
parent_sha      string(40)
branch          string NOT NULL DEFAULT 'main'
committed_at    datetime
metadata        jsonb DEFAULT {}
created_at      datetime
updated_at      datetime

UNIQUE INDEX (project_id, commit_sha)
INDEX (project_id, committed_at DESC)
```

**`collector_runs`**

```
id                  bigint PK
project_version_id  bigint FK → project_versions (NOT NULL)
collector_type      string(100) NOT NULL   -- e.g. "ast_grep_routes", "scc_stats", "ruby_maat_churn"
status              string(50) NOT NULL DEFAULT 'pending'
                    -- pending | running | completed | failed | stale
started_at          datetime
completed_at        datetime
duration_ms         integer
artifacts_count     integer DEFAULT 0
error_message       text
tool_version        string(100)           -- e.g. "ast-grep 0.41.0"
metadata            jsonb DEFAULT {}
created_at          datetime
updated_at          datetime

INDEX (project_version_id, collector_type)
INDEX (status)
```

**`knowledge_artifacts`**

```
id                  bigint PK
collector_run_id    bigint FK → collector_runs (NOT NULL, CASCADE)
project_id          bigint FK → projects (NOT NULL)
artifact_type       string(100) NOT NULL   -- "route", "symbol", "dependency", "churn_hotspot", "language_stat", "config_key"
scope_path          string(1000)           -- file path or logical scope
identifier          string(500)            -- "POST /api/users", "User#authenticate", "rails ~> 8.1"
content             text                   -- full structured content (JSON or text)
content_hash        string(64) NOT NULL    -- SHA-256 for dedup
metadata            jsonb DEFAULT {}
status              string(50) NOT NULL DEFAULT 'active'
                    -- active | stale | deleted
created_at          datetime
updated_at          datetime

INDEX (project_id, artifact_type, identifier)
INDEX (collector_run_id)
INDEX (content_hash)
INDEX (status)
```

**`knowledge_chunks`**

```
id                  uuid PK DEFAULT gen_random_uuid()
knowledge_artifact_id bigint FK → knowledge_artifacts (NOT NULL, CASCADE)
project_id          bigint FK → projects (NOT NULL)
chunk_type          string(50) NOT NULL    -- "definition", "summary", "context", "evidence"
content             text NOT NULL          -- the embeddable text
content_hash        string(64) NOT NULL
embedding_model     string(100)            -- "text-embedding-3-large"
scope_tags          jsonb DEFAULT []       -- ["controller", "auth", "api"]
status              string(50) NOT NULL DEFAULT 'active'
                    -- active | stale | deleted | redacted
sequence            integer DEFAULT 0      -- ordering within artifact
created_at          datetime
updated_at          datetime

INDEX (project_id, status)
INDEX (knowledge_artifact_id)
INDEX (content_hash)
```

Note: `knowledge_chunks.id` is a UUID (not bigint) because this value is used as the Qdrant point ID. UUIDs provide stable, globally unique identifiers that survive re-indexing.

**`knowledge_links`**

```
id              bigint PK
source_chunk_id uuid FK → knowledge_chunks (NOT NULL, CASCADE)
target_chunk_id uuid FK → knowledge_chunks (NOT NULL, CASCADE)
link_type       string(50) NOT NULL  -- "calls", "implements", "tests", "relates_to", "depends_on", "supersedes"
weight          decimal(5,3) DEFAULT 1.0
metadata        jsonb DEFAULT {}
created_at      datetime

UNIQUE INDEX (source_chunk_id, target_chunk_id, link_type)
INDEX (target_chunk_id)
INDEX (link_type)
```

### Implementation Tasks

- [ ] Create migration `CreateProjectVersions`
- [ ] Create migration `CreateCollectorRuns`
- [ ] Create migration `CreateKnowledgeArtifacts`
- [ ] Create migration `CreateKnowledgeChunks` (UUID PK via `id: :uuid`)
- [ ] Create migration `CreateKnowledgeLinks`
- [ ] Create `ProjectVersion` model with associations and validations
- [ ] Create `CollectorRun` model with status transitions
- [ ] Create `KnowledgeArtifact` model with scopes (by type, active, stale)
- [ ] Create `KnowledgeChunk` model with scopes (active, embeddable, by project)
- [ ] Create `KnowledgeLink` model
- [ ] Write model specs for each model (validations, associations, scopes)

### Acceptance Criteria

- [ ] `bin/rails db:migrate` succeeds
- [ ] All FK constraints are enforced at the DB level
- [ ] UUID PK on `knowledge_chunks` generates via `gen_random_uuid()`
- [ ] Models load correctly with associations navigable in both directions
- [ ] `bin/rspec` passes

### Notes / Risks

- `knowledge_chunks.id` being UUID while all other PKs are bigint is intentional — it provides a stable Qdrant point ID. This means `knowledge_links` FK columns must be UUID type.
- `knowledge_artifacts` cascade-deletes through `collector_run_id` — when a run is replaced, its artifacts and chunks are cleaned up.
- Consider adding `pg_trgm` extension for trigram indexing on `knowledge_artifacts.identifier` in a follow-up.

---

## Issue 3: Qdrant Collection Management — Create, Upsert, Delete, Rebuild

**Labels:** `knowledge`, `qdrant`
**Depends on:** Issue 1, Issue 2

### Background / Why

With Qdrant running and the Postgres schema in place, we need a service layer that manages Qdrant collections (one per project), upserts points from `KnowledgeChunk` records, deletes stale points, and supports full rebuild. The Qdrant collection is a derived index — Postgres is always the source of truth.

### Scope

**In scope:**

- `Knowledge::Qdrant::CollectionManager` service to create/delete collections per project
- `Knowledge::Qdrant::PointSync` service to upsert/delete points from chunks
- Collection naming convention: `project_{project.id}`
- Qdrant payload schema: `project_id`, `project_version_id`, `artifact_type`, `scope_tags`, `status`, `created_at`
- Rebuild command that drops and recreates a collection from Postgres data
- Collection deletion on project destroy (callback or job)

**Out of scope:**

- Embedding generation (Issue 8)
- Search/retrieval (Issue 10)

### Proposed Design

**Qdrant point structure:**

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "vector": [0.012, -0.034, ...],
  "payload": {
    "project_id": 42,
    "project_version_id": 17,
    "artifact_type": "route",
    "scope_tags": ["controller", "api"],
    "status": "active",
    "created_at": "2026-03-01T12:00:00Z"
  }
}
```

**Collection config:**

- Vector size: 3072 (text-embedding-3-large) — configurable via ENV
- Distance metric: Cosine
- Payload indexes on: `project_version_id`, `artifact_type`, `status`

**Service API:**

```ruby
Knowledge::Qdrant::CollectionManager.ensure_collection!(project)
Knowledge::Qdrant::CollectionManager.drop_collection!(project)
Knowledge::Qdrant::CollectionManager.rebuild_schema!(project)

Knowledge::Qdrant::PointSync.upsert_chunk!(chunk, vector:)
Knowledge::Qdrant::PointSync.delete_chunks!(chunk_ids)
Knowledge::Qdrant::PointSync.delete_by_filter!(project_id:, filters: {})
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/qdrant/collection_manager.rb`
- [ ] Create `app/services/knowledge/qdrant/point_sync.rb`
- [ ] Add `after_destroy_commit` callback on `Project` to enqueue collection cleanup
- [ ] Write specs with mocked Qdrant client
- [ ] Add `EMBEDDING_DIMENSIONS` config to `config/initializers/qdrant.rb`

### Acceptance Criteria

- [ ] `CollectionManager.ensure_collection!` is idempotent
- [ ] `PointSync.upsert_chunk!` creates/updates a Qdrant point with correct payload
- [ ] `PointSync.delete_chunks!` removes points by UUID
- [ ] `rebuild_schema!` drops and recreates collection structure (re-embedding is a separate workflow)
- [ ] Project deletion triggers collection cleanup
- [ ] `bin/rspec` passes

### Notes / Risks

- Qdrant upserts are idempotent by point ID (the chunk UUID). Safe to retry.
- Keep Qdrant payloads minimal — never store `content` text in Qdrant. Content lives in Postgres.
- Rebuild is a blunt tool for recovery. It requires re-embedding all chunks, which costs money. Log a warning before executing.

---

## Issue 4: Collector Framework — Orchestration, Storage, Idempotency, Staleness

**Labels:** `knowledge`, `agents`
**Depends on:** Issue 2

### Background / Why

Collectors are the data-gathering layer — they run tools (ast-grep, scc, ruby-maat) against a project version and produce `KnowledgeArtifact` + `KnowledgeChunk` records. We need a framework that: creates a `ProjectVersion` for the current HEAD, runs collectors in order, stores results idempotently, and marks older results as stale when HEAD advances.

### Scope

**In scope:**

- `Knowledge::CollectorRunner` orchestrator service
- `Knowledge::BaseCollector` abstract class with a standard interface
- `ProjectVersion` resolution: find-or-create for a given commit SHA
- Idempotent storage: skip artifacts whose `content_hash` hasn't changed
- Staleness: mark artifacts from prior versions as `stale` when a new version is collected
- `CollectorRun` lifecycle: pending → running → completed/failed
- GoodJob job `RunCollectorsJob` to trigger collection for a project

**Out of scope:**

- Specific collector implementations (Issues 6, 7)
- Embedding generation (Issue 8)
- Running collectors inside agent containers (Issue 9)

### Proposed Design

**CollectorRunner orchestration flow:**

```
1. Resolve project HEAD → find_or_create ProjectVersion
2. For each registered collector:
   a. Create CollectorRun (project_version_id, collector_type, status: running)
   b. Call collector.collect(project_version, collector_run)
   c. Collector yields KnowledgeArtifact records with chunks
   d. Idempotent upsert: compare content_hash, skip unchanged
   e. Mark CollectorRun completed with artifacts_count
3. Mark artifacts from older versions as stale (where project_version_id < current AND status = active)
4. Return summary
```

**BaseCollector interface:**

```ruby
module Knowledge
  class BaseCollector
    def initialize(project:, project_version:, collector_run:)
    end

    # Must return Array<Hash> of artifact data:
    # { artifact_type:, scope_path:, identifier:, content:, metadata:, chunks: [...] }
    def collect
      raise NotImplementedError
    end

    def collector_type
      raise NotImplementedError
    end

    def tool_version
      nil  # override in subclass
    end
  end
end
```

**Idempotency rule:** An artifact is identified by `(collector_run.project_version_id, artifact_type, scope_path, identifier)`. If the `content_hash` matches an existing active artifact for the same project (any version), reuse it (update the `collector_run_id` to the new run). If the hash differs, create a new artifact and mark the old one stale.

### Implementation Tasks

- [ ] Create `app/services/knowledge/collector_runner.rb`
- [ ] Create `app/services/knowledge/base_collector.rb`
- [ ] Add `Knowledge::ArtifactStore` service for idempotent create/update logic
- [ ] Add staleness-marking logic (bulk update artifacts from prior versions)
- [ ] Create `app/jobs/run_collectors_job.rb` (GoodJob)
- [ ] Register collector types in a configuration hash (collector_type → class)
- [ ] Write specs for runner orchestration, idempotency, and staleness marking

### Acceptance Criteria

- [ ] Running collectors twice on the same commit SHA produces identical artifact counts (idempotent)
- [ ] Advancing to a new commit SHA marks prior version's artifacts as `stale`
- [ ] `CollectorRun` status transitions are tracked (pending → running → completed/failed)
- [ ] `collector_runs.duration_ms` is recorded
- [ ] `collector_runs.tool_version` is populated by each collector
- [ ] Failed collectors don't block other collectors
- [ ] `bin/rspec` passes

### Notes / Risks

- Staleness is per-project — never cross-project.
- Collectors should be safe to run concurrently per project version. Use `CollectorRun` uniqueness (project_version_id + collector_type) to prevent duplicate runs.
- Consider a `UNIQUE INDEX (project_version_id, collector_type)` on `collector_runs` to enforce this at the DB level.

---

## Issue 5: Thin Vertical Slice — Routes Collector → Postgres → Qdrant → Query API

**Labels:** `knowledge`, `qdrant`, `agents`
**Depends on:** Issues 1, 2, 3, 4, 8

### Background / Why

This is the "tracer bullet" issue. It proves the entire pipeline works end-to-end with a single, concrete collector: extracting Rails routes (or a language-agnostic endpoint index) from a project, storing them as artifacts/chunks in Postgres, embedding and upserting to Qdrant, and answering queries like "what handles POST /api/users?" (exact) and "how do I add a new endpoint?" (semantic).

### Scope

**In scope:**

- `Knowledge::Collectors::RoutesCollector` — parses route output to produce artifacts
- End-to-end pipeline: collect → store → embed → upsert → query
- Exact lookup API: `GET /api/knowledge/search?project_id=X&type=route&q=POST+/api/users`
- Semantic query API: `GET /api/knowledge/search?project_id=X&q=how+do+I+add+a+new+endpoint`
- Basic re-rank: prefer current version, active status
- Integration test that runs the full pipeline against a sample project fixture

**Out of scope:**

- Full collector suite (Issues 6, 7)
- Production UI (Issue 15)
- Agent integration (Issue 11)

### Proposed Design

**RoutesCollector logic:**

1. Run `bin/rails routes --expanded` (Ruby/Rails) or parse a generic routes file inside the project's container
2. Parse output into structured route entries
3. For each route, produce a `KnowledgeArtifact` of type `"route"`:

   ```json
   {
     "artifact_type": "route",
     "scope_path": "config/routes.rb",
     "identifier": "POST /api/users",
     "content": "POST /api/users → UsersController#create (prefix: api_users)",
     "metadata": {
       "http_method": "POST",
       "path": "/api/users",
       "controller": "UsersController",
       "action": "create"
     }
   }
   ```

4. Each artifact produces one `KnowledgeChunk` with embeddable text:

   ```
   Route: POST /api/users
   Controller: UsersController#create
   Purpose: Creates a new user via the API
   ```

**Query API (thin, internal-first):**

```
GET /api/knowledge/search
  ?project_id=42
  &q=POST /api/users           # exact → Postgres lookup on identifier
  &mode=exact|semantic|hybrid   # default: hybrid

Response:
{
  "results": [
    {
      "chunk_id": "550e8400-...",
      "artifact_type": "route",
      "identifier": "POST /api/users",
      "content": "...",
      "score": 0.95,
      "source": "exact",
      "project_version": { "commit_sha": "abc123", "committed_at": "..." }
    }
  ],
  "meta": { "mode": "hybrid", "total": 1, "took_ms": 42 }
}
```

### Implementation Tasks

- [ ] Implement `Knowledge::Collectors::RoutesCollector < BaseCollector`
- [ ] Add route parsing logic (handle `rails routes` output format)
- [ ] Wire `RoutesCollector` into the collector registry
- [ ] Implement `Knowledge::Search` service with `exact`, `semantic`, and `hybrid` modes
- [ ] Create `Api::KnowledgeSearchController` with `search` action
- [ ] Add route: `GET /api/knowledge/search`
- [ ] Write integration test: collect → embed → query "POST /api/users" → get result
- [ ] Write integration test: semantic query "how do I add a new endpoint" → get relevant results

### Acceptance Criteria

- [ ] `RoutesCollector` extracts routes and stores artifacts + chunks in Postgres
- [ ] Chunks are embedded and upserted to Qdrant
- [ ] `GET /api/knowledge/search?project_id=X&q=POST+/api/users&mode=exact` returns the correct route
- [ ] `GET /api/knowledge/search?project_id=X&q=how+do+I+add+a+new+endpoint&mode=semantic` returns relevant route chunks
- [ ] Hybrid mode merges exact and semantic results with deduplication
- [ ] Results include project version info (commit SHA)
- [ ] Response time < 500ms for semantic queries (on warm Qdrant)
- [ ] Integration tests pass end-to-end

### Notes / Risks

- For non-Rails projects, the routes collector should gracefully return empty results or fall back to scanning for common patterns (Express routes, FastAPI decorators, etc.). Start with Rails-only, add others later.
- The query API is internal (for agent consumption). No public auth required yet — it's behind the same auth as the rest of the app.
- This is the most important issue to validate the architecture. Ship it before expanding the collector suite.

---

## Issue 6: Static Collectors — ast-grep Symbols, Dependencies, Config Keys

**Labels:** `knowledge`, `agents`
**Depends on:** Issue 4

### Background / Why

Static collectors extract structural knowledge from source code without running it. Using ast-grep (already available in the agent image), we can build a symbol index (classes, methods, modules), parse dependency manifests (Gemfile, package.json), and extract configuration keys. These are high-value, low-risk collectors.

### Scope

**In scope:**

- `Knowledge::Collectors::SymbolIndexCollector` — uses ast-grep to extract class, method, and module definitions
- `Knowledge::Collectors::DependencyCollector` — parses Gemfile, package.json, requirements.txt, go.mod
- `Knowledge::Collectors::ConfigKeyCollector` — extracts config/env references (ENV[], Rails.application.config, etc.)
- ast-grep rule definitions for Ruby, JavaScript/TypeScript, Python, Go
- Chunking strategy: one chunk per symbol/dependency/config key

**Out of scope:**

- Runtime collectors (traces, logs)
- Schema/migration analysis (could be a follow-up)
- Running inside agent containers (Issue 9)

### Proposed Design

**SymbolIndexCollector:**

- Runs `ast-grep` with language-specific rules to extract definitions
- Ruby rules: `class $NAME`, `module $NAME`, `def $NAME`, `scope :$NAME`
- JS/TS rules: `function $NAME`, `class $NAME`, `export const $NAME`
- Artifact type: `"symbol"`
- Identifier: `"User#authenticate"`, `"ApplicationController"`, `"UsersHelper.format_name"`

**DependencyCollector:**

- Parses lockfiles/manifests directly (no external tool needed)
- Artifact type: `"dependency"`
- Identifier: `"rails ~> 8.1"`, `"react ^18.2.0"`
- Metadata includes: name, version constraint, source, group (dev/prod/test)

**ConfigKeyCollector:**

- Uses ast-grep or grep to find `ENV["KEY"]`, `ENV.fetch("KEY")`, `Rails.application.config.x.*`
- Artifact type: `"config_key"`
- Identifier: `"DATABASE_URL"`, `"QDRANT_URL"`
- Chunks include the file path and line number for context

### Implementation Tasks

- [ ] Create ast-grep rule files under `config/knowledge/ast_grep_rules/`
- [ ] Implement `Knowledge::Collectors::SymbolIndexCollector`
- [ ] Implement `Knowledge::Collectors::DependencyCollector`
- [ ] Implement `Knowledge::Collectors::ConfigKeyCollector`
- [ ] Register all three collectors in the collector registry
- [ ] Write specs for each collector with fixture files
- [ ] Verify ast-grep binary is accessible from the Rails app (or document the requirement)

### Acceptance Criteria

- [ ] SymbolIndexCollector extracts classes, modules, and methods from a Ruby file fixture
- [ ] DependencyCollector parses a Gemfile fixture and produces one artifact per dependency
- [ ] ConfigKeyCollector extracts ENV references from a Ruby file fixture
- [ ] Each collector produces properly hashed artifacts (idempotent re-runs)
- [ ] `tool_version` is populated (e.g., `ast-grep 0.41.0`)
- [ ] `bin/rspec` passes

### Notes / Risks

- ast-grep must be installed on the host where collectors run. In dev, it's in the agent image. For the Rails app host, we may need to install it separately or run collectors inside containers (Issue 9).
- Start with Ruby rules only for the symbol index; add JS/TS/Python rules iteratively.
- Dependency parsing for lockfiles is well-defined; manifest parsing (version resolution) is out of scope.

---

## Issue 7: Analytical Collectors — ruby-maat Churn/Hotspots + scc Language Stats

**Labels:** `knowledge`, `agents`
**Depends on:** Issue 4

### Background / Why

Beyond static structure, agents benefit from knowing *which files change most* (churn hotspots), *which are most complex* (complexity scores), and *what languages/sizes* the project has. ruby-maat provides churn, hotspot, and authorship analysis from git history; scc provides fast language breakdown and line counts.

### Scope

**In scope:**

- `Knowledge::Collectors::ChurnHotspotCollector` — runs ruby-maat to produce churn and hotspot artifacts
- `Knowledge::Collectors::LanguageStatsCollector` — runs scc to produce language breakdown artifacts
- Artifact types: `"churn_hotspot"`, `"language_stat"`
- Chunks summarize hotspot rankings and language distribution for semantic queries

**Out of scope:**

- Authorship analysis (privacy-sensitive; defer to a later issue)
- Complexity-weighted churn (requires further ruby-maat integration)

### Proposed Design

**ChurnHotspotCollector:**

- Runs `maat -c git2 -l <repo> -a revisions` and `maat -c git2 -l <repo> -a hotspots`
- Produces one artifact per file in the hotspot ranking:

  ```json
  {
    "artifact_type": "churn_hotspot",
    "scope_path": "app/models/agent_run.rb",
    "identifier": "app/models/agent_run.rb",
    "content": "Churn hotspot: app/models/agent_run.rb — 47 revisions, complexity score 23",
    "metadata": { "revisions": 47, "complexity": 23, "rank": 3 }
  }
  ```

- Chunk text: `"app/models/agent_run.rb is a high-churn file (47 revisions, rank #3). Changes here need careful review."`

**LanguageStatsCollector:**

- Runs `scc --format json <repo>`
- Produces one artifact per language:

  ```json
  {
    "artifact_type": "language_stat",
    "identifier": "Ruby",
    "content": "Ruby: 15,234 lines of code across 187 files",
    "metadata": { "files": 187, "lines": 15234, "code": 12456, "comments": 1890, "blanks": 888 }
  }
  ```

### Implementation Tasks

- [ ] Implement `Knowledge::Collectors::ChurnHotspotCollector`
- [ ] Implement `Knowledge::Collectors::LanguageStatsCollector`
- [ ] Register both collectors in the collector registry
- [ ] Parse ruby-maat CSV output into structured data
- [ ] Parse scc JSON output into structured data
- [ ] Write specs with sample tool output fixtures
- [ ] Verify ruby-maat and scc binaries are accessible

### Acceptance Criteria

- [ ] ChurnHotspotCollector produces ranked hotspot artifacts from ruby-maat output
- [ ] LanguageStatsCollector produces per-language artifacts from scc output
- [ ] Both collectors handle empty/missing tool output gracefully (no crash)
- [ ] Metadata fields are populated for downstream ranking
- [ ] `bin/rspec` passes

### Notes / Risks

- ruby-maat requires git history — shallow clones won't work. Ensure full clone depth or at least 6 months of history.
- scc is fast (~1s for large repos) but ruby-maat can be slow on repos with deep history. Set timeouts.
- Both tools must be installed where collectors run. Same concern as Issue 6 re: host vs. container.

---

## Issue 8: Embedding Pipeline — Chunking, Generation, Qdrant Upsert

**Labels:** `knowledge`, `qdrant`, `security`
**Depends on:** Issues 2, 3

### Background / Why

Knowledge chunks in Postgres need vector embeddings stored in Qdrant for semantic retrieval. This issue builds the pipeline: take a `KnowledgeChunk`, generate its embedding via agent-harness (respecting the "all LLM calls through agent-harness" mandate), and upsert the point to Qdrant.

### Scope

**In scope:**

- `Knowledge::Embeddings::Generate` service — calls agent-harness to generate embeddings
- `Knowledge::Embeddings::Pipeline` service — orchestrates: filter eligible chunks → generate embeddings → upsert to Qdrant
- Batch processing with configurable batch size
- Record `embedding_model` on `KnowledgeChunk` after generation
- Redaction check before embedding (call to redaction service, Issue 13)
- GoodJob job `EmbedChunksJob` to process new/updated chunks
- Cost tracking for embedding API calls

**Out of scope:**

- Redaction implementation (Issue 13 — this issue just calls the interface)
- Search/retrieval (Issue 10)

### Proposed Design

**Embedding generation via agent-harness:**

```ruby
module Knowledge
  module Embeddings
    class Generate
      MODEL = "text-embedding-3-large"
      DIMENSIONS = 3072

      def self.call(texts:)
        # agent-harness is the sole LLM interface per architectural mandate
        AgentHarness.embed(texts, model: MODEL)
      end
    end
  end
end
```

If `AgentHarness.embed` is not yet available, implement as a thin wrapper around the appropriate provider API, routed through agent-harness configuration. File an agent-harness issue if the method doesn't exist.

**Pipeline flow:**

```
1. Query: KnowledgeChunk.where(status: 'active', embedding_model: nil).limit(batch_size)
2. For each batch:
   a. Run redaction check (placeholder: pass-through until Issue 13)
   b. Call Generate.call(texts: batch.map(&:content))
   c. For each (chunk, vector) pair:
      - PointSync.upsert_chunk!(chunk, vector: vector)
      - chunk.update!(embedding_model: MODEL)
3. Log: chunks embedded, cost estimate, duration
```

**Cost tracking:**

- text-embedding-3-large: ~$0.13 per 1M tokens
- Track total tokens embedded per `CollectorRun` for cost reporting

### Implementation Tasks

- [ ] Create `app/services/knowledge/embeddings/generate.rb`
- [ ] Create `app/services/knowledge/embeddings/pipeline.rb`
- [ ] Create `app/jobs/embed_chunks_job.rb` (GoodJob, queue: `knowledge`)
- [ ] Add `embedding_model` update logic to chunk records
- [ ] Add redaction check call point (no-op until Issue 13)
- [ ] Add batch size configuration (ENV `EMBEDDING_BATCH_SIZE`, default 100)
- [ ] Write specs with mocked agent-harness embedding calls
- [ ] Add cost estimation logging

### Acceptance Criteria

- [ ] Pipeline generates embeddings for all unembedded active chunks
- [ ] Qdrant points are upserted with correct vectors and payload
- [ ] `embedding_model` is recorded on each processed chunk
- [ ] Batch processing respects configured batch size
- [ ] Pipeline is idempotent (re-running on already-embedded chunks is a no-op)
- [ ] Cost is logged per pipeline run
- [ ] `bin/rspec` passes

### Notes / Risks

- **Cost**: Embedding a large codebase (~10K files) costs approximately $1–5 per full run. Incremental runs are much cheaper. Track and alert.
- **Rate limits**: Embedding APIs have rate limits. Implement backoff in `Generate.call`.
- **Agent-harness embedding support**: Verify that agent-harness supports an `embed` method. If not, implement a direct API call as a temporary measure and file an issue on agent-harness.
- Never embed content that hasn't passed the redaction check (Issue 13).

---

## Issue 9: Containerized Collector Execution via Agent-Harness

**Labels:** `knowledge`, `agents`, `infra`
**Depends on:** Issues 4, 6, 7

### Background / Why

Collectors need access to the project's source code and tools (ast-grep, scc, ruby-maat). The agent image (`paid-agent:latest`) already has these tools installed. Rather than requiring them on the Rails host, we should run collectors inside containerized environments using the existing container provisioning infrastructure, similar to how agent runs work.

### Scope

**In scope:**

- `Knowledge::ContainerizedRunner` service that provisions a lightweight container, clones the repo, runs collectors, and extracts results
- Reuse `Containers::Provision` and `Containers::GitOperations` for container + clone
- Execute collector tool commands inside the container, pipe results back to Postgres
- Cleanup container after collection completes
- Optionally integrate with Temporal as a `RunCollectorsActivity`

**Out of scope:**

- New Docker images (reuse `paid-agent:latest`)
- Container networking changes

### Proposed Design

**Flow:**

```
1. Provision container (paid-agent:latest, read-only, no API key proxy needed)
2. Clone repo at target commit SHA
3. For each collector:
   a. Execute tool command inside container (e.g., `ast-grep scan --rule ...`, `scc --format json`)
   b. Capture stdout as raw output
   c. Parse output on the Rails side (not in container)
   d. Store artifacts/chunks in Postgres
4. Cleanup container
```

**Key difference from agent runs:** No API key proxy needed. Collectors are read-only analysis — they don't call LLMs or write code. The container can run on the restricted `paid_agent` network with no internet access, or even with `--network=none`.

### Implementation Tasks

- [ ] Create `app/services/knowledge/containerized_runner.rb`
- [ ] Add `collector` container mode to `Containers::Provision` (no proxy, no API keys, shorter timeout)
- [ ] Implement result extraction via `container.exec` stdout capture
- [ ] Wire `RunCollectorsJob` to use `ContainerizedRunner` when available
- [ ] Create `Activities::RunCollectorsActivity` for Temporal integration
- [ ] Write specs with Docker mocks

### Acceptance Criteria

- [ ] Collectors run inside a container with the project cloned at the target SHA
- [ ] No API keys or secrets are exposed to the collector container
- [ ] Container is cleaned up after collection (success or failure)
- [ ] Results are correctly parsed and stored in Postgres
- [ ] Fallback to host execution when Docker is unavailable (dev convenience)
- [ ] `bin/rspec` passes

### Notes / Risks

- Container startup adds ~10–30s overhead. For rapid iteration in dev, support a `COLLECTORS_USE_HOST=true` env var that skips containerization.
- The container needs git access to clone the repo. Reuse the existing git credential proxy.
- Resource limits should be tight — collectors don't need 4GB of memory. Use 512MB / 1 CPU.

---

## Issue 10: Retrieval API — Hybrid Search with Exact + Semantic + Re-ranking

**Labels:** `knowledge`, `qdrant`
**Depends on:** Issues 3, 5, 8

### Background / Why

Agents and (eventually) humans need to query the knowledge base. This issue builds the full retrieval layer with three modes: exact lookup from Postgres (routes, symbols, dependencies by identifier), semantic search from Qdrant (natural-language questions), and hybrid mode that merges both with a re-ranking strategy.

### Scope

**In scope:**

- `Knowledge::Search::Exact` — Postgres queries on `knowledge_artifacts.identifier` with LIKE/ILIKE/trigram
- `Knowledge::Search::Semantic` — Qdrant vector search with payload filters
- `Knowledge::Search::Hybrid` — orchestrates both, deduplicates, re-ranks
- `Knowledge::Search::Reranker` — scoring: prefer matching commit SHA, evidence-backed chunks, newer runs, non-superseded
- Postgres full-text search via `tsvector` on `knowledge_chunks.content` (lexical mode)
- `Api::KnowledgeSearchController` with search action (from Issue 5, extended)
- Query parameter interface: `project_id`, `q`, `mode`, `artifact_type`, `version` (commit SHA), `limit`

**Out of scope:**

- UI (Issue 15)
- Agent integration (Issue 11)
- Advanced NLP re-ranking (use heuristic scoring first)

### Proposed Design

**Re-ranking heuristic:**

```ruby
def score(result, query_context)
  base = result.vector_score || 0.0

  # Boost for matching requested version
  base += 0.15 if result.commit_sha == query_context.target_sha

  # Boost for active (non-stale) status
  base += 0.10 if result.status == "active"

  # Boost for evidence-backed chunks (linked to other artifacts)
  base += 0.05 * [result.link_count, 3].min

  # Penalize old collector runs
  age_days = (Time.current - result.created_at) / 1.day
  base -= 0.01 * [age_days, 10].min

  base
end
```

**API response shape:**

```json
{
  "results": [
    {
      "chunk_id": "550e8400-...",
      "artifact_type": "route",
      "identifier": "POST /api/users",
      "content": "Route: POST /api/users → UsersController#create",
      "score": 0.92,
      "source": "hybrid",
      "project_version": {
        "commit_sha": "abc123def",
        "committed_at": "2026-03-01T12:00:00Z"
      },
      "scope_tags": ["controller", "api"],
      "collector_run_id": 17
    }
  ],
  "meta": {
    "mode": "hybrid",
    "total": 15,
    "took_ms": 87,
    "exact_count": 3,
    "semantic_count": 12
  }
}
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/search/exact.rb`
- [ ] Create `app/services/knowledge/search/semantic.rb`
- [ ] Create `app/services/knowledge/search/hybrid.rb`
- [ ] Create `app/services/knowledge/search/reranker.rb`
- [ ] Add migration to add `tsvector` column to `knowledge_chunks` for full-text search
- [ ] Add GIN index on the `tsvector` column
- [ ] Extend `Api::KnowledgeSearchController` with full parameter support
- [ ] Write specs for each search mode
- [ ] Write integration spec: hybrid search returns both exact and semantic results, merged and ranked

### Acceptance Criteria

- [ ] Exact mode finds artifacts by identifier substring match
- [ ] Semantic mode returns Qdrant results filtered by project and optionally by artifact_type
- [ ] Hybrid mode merges and deduplicates exact + semantic results
- [ ] Re-ranker boosts results matching the requested commit SHA
- [ ] Full-text/lexical search works via Postgres tsvector
- [ ] API returns results with version info and scores
- [ ] Response time < 500ms for hybrid queries
- [ ] `bin/rspec` passes

### Notes / Risks

- Re-ranking is heuristic-based for now. Track query logs to tune weights later.
- Postgres `pg_trgm` extension may be needed for fuzzy identifier matching. Add migration to enable it.
- Consider adding `EXPLAIN ANALYZE` logging for slow exact queries.

---

## Issue 11: Agent Context Bundle Builder for Agent-Harness Consumption

**Labels:** `knowledge`, `agents`
**Depends on:** Issue 10

### Background / Why

The knowledge base is only valuable if agents actually use it. This issue builds the "context bundle" — a curated package of knowledge injected into agent prompts before execution. The bundle is tailored to the issue being worked on and the project's current state.

### Scope

**In scope:**

- `Knowledge::ContextBundle::Build` service — takes an issue + project, queries the knowledge base, and produces a structured context block
- Integration into `Prompts::BuildForIssue` to inject knowledge context
- Context budget management: stay within a token limit (configurable, default ~4K tokens)
- Section ordering: routes → symbols → hotspots → conventions → decision records
- Integration into `AgentExecutionWorkflow` via the existing prompt-building step

**Out of scope:**

- Modifying the agent-harness gem itself
- Dynamic context expansion (agent requesting more context mid-run)

### Proposed Design

**Context bundle structure (injected into prompt):**

```markdown
## Codebase Context (auto-generated from knowledge base)

### Relevant Routes
- POST /api/users → UsersController#create
- GET /api/users/:id → UsersController#show

### Related Code
- `app/models/user.rb` — User model with Devise authentication (lines 1–45)
- `app/services/users/create.rb` — User creation service

### Hotspot Warning
- `app/models/user.rb` is a high-churn file (47 revisions). Changes need careful review.

### Recent Decisions
- DR-7: "Use Devise for authentication" (active, 2026-02-15)

### Project Stats
- Primary language: Ruby (15,234 LOC across 187 files)
- Test framework: RSpec
```

**Build flow:**

```ruby
bundle = Knowledge::ContextBundle::Build.call(
  issue: issue,
  project: project,
  token_budget: 4000
)
# Returns { sections: [...], total_tokens: 3847, queries_made: 4 }
```

**Integration point in `Prompts::BuildForIssue`:**

```ruby
def build
  # ... existing prompt sections ...
  knowledge_context = Knowledge::ContextBundle::Build.call(
    issue: @issue,
    project: @project
  )
  # Append knowledge context section to prompt
end
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/context_bundle/build.rb`
- [ ] Implement section builders for routes, symbols, hotspots, decisions, and stats
- [ ] Implement token budget management (truncate sections to fit)
- [ ] Integrate into `Prompts::BuildForIssue`
- [ ] Add `KNOWLEDGE_CONTEXT_TOKEN_BUDGET` ENV config (default 4000)
- [ ] Write specs for bundle building with various knowledge states (empty, partial, full)
- [ ] Write spec verifying bundle stays within token budget

### Acceptance Criteria

- [ ] Context bundle includes relevant routes, symbols, and hotspots for a given issue
- [ ] Bundle respects the token budget (never exceeds it)
- [ ] When no knowledge exists, the bundle section is omitted (no empty headers)
- [ ] Integration with `Prompts::BuildForIssue` works end-to-end
- [ ] Agent prompts include knowledge context in test runs
- [ ] `bin/rspec` passes

### Notes / Risks

- Token counting should use a fast approximation (words / 0.75) rather than a tokenizer dependency.
- The bundle builder makes multiple knowledge queries — ensure total latency stays under 1s.
- If the knowledge base is empty for a project (no collectors have run), gracefully skip the section.

---

## Issue 12: Decision Records — Why Capture Integrated into Agent Workflows

**Labels:** `knowledge`, `agents`
**Depends on:** Issue 2

### Background / Why

The knowledge base must capture not just "what" (current code state) but "why" (decisions and reasoning). For each non-trivial change, Paid should capture a Decision Record (ADR-lite) attached to a changeset (PR/commit range) with evidence links. Agents should draft decision records as part of their workflow, and records should be queryable alongside other knowledge.

### Scope

**In scope:**

- Migration: `decision_records` table
- Migration: `decision_record_links` table (evidence links to chunks, PRs, issues)
- `DecisionRecord` model with immutable content + status transitions
- `Knowledge::Decisions::Draft` service — agent-harness call to draft a decision record from a completed agent run
- `Knowledge::Decisions::Supersede` service — marks a decision as superseded by a newer one
- Integration into `AgentExecutionWorkflow` post-PR-creation step
- Decision records stored as `KnowledgeArtifact` type `"decision_record"` for unified search

**Out of scope:**

- Manual decision record creation UI (Issue 15)
- Approval workflows for decision records

### Proposed Design

**`decision_records`**

```
id              bigint PK
project_id      bigint FK → projects (NOT NULL)
agent_run_id    bigint FK → agent_runs (nullable)  -- which run produced this
issue_id        bigint FK → issues (nullable)       -- which issue prompted this
title           string(500) NOT NULL
summary         text NOT NULL                        -- 1-3 sentence summary
context         text                                 -- background/situation
decision        text NOT NULL                        -- what was decided
consequences    text                                 -- expected outcomes
status          string(50) NOT NULL DEFAULT 'active'
                -- active | superseded | reverted | draft
superseded_by_id bigint FK → decision_records (nullable)
commit_sha_start string(40)                          -- changeset start
commit_sha_end   string(40)                          -- changeset end (usually result_commit_sha)
tags            jsonb DEFAULT []                     -- ["auth", "api", "performance"]
created_at      datetime
updated_at      datetime

INDEX (project_id, status)
INDEX (project_id, tags) USING GIN
```

**`decision_record_links`**

```
id                  bigint PK
decision_record_id  bigint FK → decision_records (NOT NULL, CASCADE)
linkable_type       string(100) NOT NULL   -- "KnowledgeChunk", "Issue", "AgentRun"
linkable_id         string(100) NOT NULL   -- bigint or UUID as string
link_type           string(50) NOT NULL    -- "evidence", "implements", "reverts"
created_at          datetime

INDEX (decision_record_id)
INDEX (linkable_type, linkable_id)
```

**Draft flow (post-PR creation):**

```ruby
# In AgentExecutionWorkflow, after CreatePullRequestActivity:
run_activity(Activities::DraftDecisionRecordActivity,
  { agent_run_id: agent_run_id }, timeout: 60)
```

The activity calls:

```ruby
Knowledge::Decisions::Draft.call(agent_run: agent_run)
# 1. Summarize what changed (from agent run logs/PR diff)
# 2. Call agent-harness to draft a decision record
# 3. Store as DecisionRecord + create a KnowledgeArtifact + KnowledgeChunk
# 4. Link to the agent run, issue, and any modified knowledge artifacts
```

**Supersede flow:**

```ruby
Knowledge::Decisions::Supersede.call(
  original: old_decision,
  superseding: new_decision,
  reason: "Updated auth approach from session-based to JWT"
)
# Sets old.status = "superseded", old.superseded_by_id = new.id
```

### Implementation Tasks

- [ ] Create migration `CreateDecisionRecords`
- [ ] Create migration `CreateDecisionRecordLinks`
- [ ] Create `DecisionRecord` model with status transitions, immutability validation
- [ ] Create `DecisionRecordLink` model (polymorphic)
- [ ] Create `app/services/knowledge/decisions/draft.rb`
- [ ] Create `app/services/knowledge/decisions/supersede.rb`
- [ ] Create `Activities::DraftDecisionRecordActivity`
- [ ] Integrate activity into `AgentExecutionWorkflow` (after PR creation, best-effort)
- [ ] Create a `Knowledge::Collectors::DecisionRecordCollector` that indexes decision records as artifacts/chunks
- [ ] Write specs for models, services, and activity

### Acceptance Criteria

- [ ] Decision records are created after successful PR-creating agent runs
- [ ] Records include title, summary, context, decision, consequences, and commit SHA range
- [ ] Records are immutable after creation (only `status` can change)
- [ ] Supersede correctly links old → new and updates status
- [ ] Decision records are indexed as knowledge artifacts and searchable
- [ ] Failed draft attempts don't break the agent workflow (best-effort)
- [ ] `bin/rspec` passes

### Notes / Risks

- Decision record drafting uses an LLM call. Keep the prompt concise and set a short timeout (30s). The draft quality doesn't need to be perfect — it's a starting point.
- Use `DecisionRecordLink` with polymorphic linkable to support linking to chunks (UUID), issues (bigint), and agent runs (bigint). Store all IDs as strings to handle both types.
- Immutability is enforced at the model level via `before_update` callback that rejects changes to content fields.

---

## Issue 13: Redaction Pipeline — Sensitive Data Handling Before Embedding

**Labels:** `knowledge`, `security`
**Depends on:** Issue 2

### Background / Why

Code and configuration often contain secrets (API keys, passwords, tokens), PII (emails, names), and internal URLs. These must never be embedded as vectors or stored in Qdrant payloads. A redaction pipeline runs before chunking/embedding to detect and mask sensitive content.

### Scope

**In scope:**

- `Knowledge::Redaction::Scanner` — detects sensitive patterns in text
- `Knowledge::Redaction::Redactor` — replaces detected patterns with placeholders
- Pattern library: API keys, passwords, emails, IP addresses, JWT tokens, AWS keys, GitHub tokens, connection strings
- Integration point in the embedding pipeline (Issue 8)
- Redaction audit log — record what was redacted (pattern type, file, line) without storing the secret
- `KnowledgeChunk` status `"redacted"` for chunks that are entirely sensitive

**Out of scope:**

- ML-based PII detection (use regex patterns first)
- Redaction of Qdrant payloads (payloads should never contain sensitive content — enforce this at upsert time)

### Proposed Design

**Scanner patterns:**

```ruby
PATTERNS = {
  api_key: /(?:api[_-]?key|apikey)\s*[:=]\s*["']?([a-zA-Z0-9_\-]{20,})["']?/i,
  aws_key: /(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}/,
  github_token: /gh[ps]_[a-zA-Z0-9]{36,}/,
  jwt: /eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/,
  password: /(?:password|passwd|secret)\s*[:=]\s*["']([^"']+)["']/i,
  email: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
  connection_string: /(?:postgres|mysql|redis|mongodb):\/\/[^\s"']+/i,
  private_key: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/
}.freeze
```

**Redaction output:**

```ruby
result = Knowledge::Redaction::Redactor.call(text: chunk_content)
# result.clean_text    → text with [REDACTED:api_key], [REDACTED:email], etc.
# result.redactions    → [{ pattern: :api_key, offset: 45, length: 40 }, ...]
# result.fully_redacted? → true if the majority of content was sensitive
```

**Audit log (structured):**

```ruby
Rails.logger.info(
  message: "knowledge.redaction",
  project_id: project.id,
  chunk_id: chunk.id,
  file_path: artifact.scope_path,
  patterns_found: [:api_key, :email],
  redaction_count: 3,
  fully_redacted: false
)
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/redaction/scanner.rb`
- [ ] Create `app/services/knowledge/redaction/redactor.rb`
- [ ] Define pattern library in `config/knowledge/redaction_patterns.yml`
- [ ] Add hook in embedding pipeline (Issue 8) to call redactor before embedding
- [ ] Add `"redacted"` to `KnowledgeChunk` status enum
- [ ] Implement structured audit logging for redaction events
- [ ] Write specs with sample sensitive content (use obviously fake secrets)
- [ ] Write specs verifying no known secret patterns pass through undetected

### Acceptance Criteria

- [ ] Scanner detects all defined patterns in test fixtures
- [ ] Redactor replaces secrets with typed placeholders (`[REDACTED:api_key]`)
- [ ] Fully sensitive chunks are marked with status `"redacted"` and not embedded
- [ ] Partially sensitive chunks are cleaned and embedded with redacted content
- [ ] Audit log records redaction events without leaking secret values
- [ ] No false positives on common code patterns (e.g., `key: :symbol` is not redacted)
- [ ] `bin/rspec` passes

### Notes / Risks

- **False positives**: Regex-based detection will have false positives. Err on the side of over-redacting — a missing code snippet is better than a leaked secret.
- **Performance**: Scanner runs on every chunk before embedding. Keep patterns compiled (Regexp constants).
- **Escape hatch**: If a legitimate code pattern is being redacted, allow per-project allowlists via `project.metadata["redaction_allowlist"]`.
- This is a security-critical service. Add a spec that runs the scanner against the Paid codebase itself as a smoke test.

---

## Issue 14: Provenance Tracking and Audit Log

**Labels:** `knowledge`, `security`, `observability`
**Depends on:** Issue 4

### Background / Why

Every piece of knowledge must have clear provenance: what generated it, when, which tool version, and from which source commit. This is essential for debugging stale/incorrect knowledge, auditing what agents see, and rebuilding the knowledge base after issues.

### Scope

**In scope:**

- Extend `CollectorRun` with detailed provenance fields (already partially in Issue 2)
- `Knowledge::Provenance::AuditLog` service for structured logging of all knowledge mutations
- Audit events: artifact_created, artifact_staled, chunk_embedded, chunk_redacted, decision_drafted, collection_rebuilt
- `Api::KnowledgeAuditController` — read-only API to query audit events for a project
- Retention policy: keep audit events for 90 days, then archive/delete

**Out of scope:**

- External audit log shipping (Datadog, Splunk)
- User-facing audit UI (Issue 15)

### Proposed Design

**Audit events table (optional — could use structured logging instead):**

If we want queryable audit history:

```
knowledge_audit_events
  id              bigint PK
  project_id      bigint FK → projects (NOT NULL)
  event_type      string(100) NOT NULL
  actor_type      string(50)    -- "collector", "pipeline", "user", "system"
  actor_id        string(100)   -- collector_run_id, user_id, etc.
  target_type     string(100)   -- "KnowledgeArtifact", "KnowledgeChunk", "DecisionRecord"
  target_id       string(100)
  details         jsonb DEFAULT {}
  created_at      datetime

  INDEX (project_id, created_at DESC)
  INDEX (event_type)
  INDEX (target_type, target_id)
```

Alternative: use structured JSON logging to Rails logger (cheaper, simpler, but less queryable). **Recommendation: Start with structured logging, add the table if querying becomes necessary.**

**Structured log format:**

```ruby
Rails.logger.info(
  message: "knowledge.audit",
  event: "artifact_created",
  project_id: 42,
  actor: "collector:ast_grep_routes",
  target: "KnowledgeArtifact:789",
  details: { artifact_type: "route", identifier: "POST /api/users" }
)
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/provenance/audit_log.rb` with `.record(event:, ...)` method
- [ ] Instrument artifact creation, staleness marking, embedding, redaction, and decision drafting
- [ ] Decide: structured logging only or structured logging + DB table
- [ ] If DB table: create migration and model
- [ ] Create `Api::KnowledgeAuditController` with `index` action (paginated, filterable)
- [ ] Add route: `GET /api/knowledge/audit?project_id=X&event_type=Y`
- [ ] Write specs for audit log recording

### Acceptance Criteria

- [ ] Every knowledge mutation produces an audit log entry
- [ ] Audit entries include: who (actor), what (event), which (target), when (timestamp)
- [ ] Provenance chain is traceable: artifact → collector_run → project_version → commit_sha
- [ ] API returns audit events filtered by project, event type, and date range
- [ ] `bin/rspec` passes

### Notes / Risks

- Start with structured logging. The table adds schema maintenance burden. Revisit if we need to query audit history programmatically (e.g., for the admin UI).
- Audit events can be high-volume during full collection runs. Batch logging if needed.
- Never log sensitive content in audit events — only references (IDs, types, counts).

---

## Issue 15: Minimal Admin UI — Inspect Artifacts, Runs, and Search Results

**Labels:** `knowledge`, `docs`
**Depends on:** Issues 5, 10

### Background / Why

Operators need visibility into the knowledge base: what was collected, when, search quality, and staleness. A minimal admin UI (or dashboard extension) surfaces this information without requiring API calls or console access.

### Scope

**In scope:**

- Dashboard widget: knowledge base health per project (last collected, artifact counts by type, stale count)
- Project detail page: list collector runs with status, duration, artifact counts
- Knowledge search page: text input → hybrid search results with scores and sources
- Artifact detail page: view artifact content, linked chunks, provenance

**Out of scope:**

- Decision record editing UI (read-only for now)
- Public-facing API documentation
- Advanced search filters

### Proposed Design

**Dashboard widget (extend existing `dashboard#show`):**

```
Knowledge Base
  Projects indexed: 3/5
  Total artifacts: 1,247
  Stale artifacts: 89 (7%)
  Last collection: 2 hours ago
```

**Project knowledge tab:**

```
Collector Runs
| Type              | Version    | Status    | Duration | Artifacts | When         |
|-------------------|------------|-----------|----------|-----------|--------------|
| ast_grep_routes   | 0.41.0     | completed | 3.2s     | 47        | 2h ago       |
| scc_stats         | 3.6.0      | completed | 1.1s     | 12        | 2h ago       |
| ruby_maat_churn   | 0.9.0      | completed | 18.4s    | 156       | 2h ago       |
```

**Search page:**
Simple text input + project selector. Results displayed as cards with score, artifact type, identifier, content preview, and version info.

### Implementation Tasks

- [ ] Add `Knowledge::DashboardStats` service
- [ ] Extend `dashboard#show` view with knowledge widget
- [ ] Add knowledge tab to project show page
- [ ] Create `Knowledge::SearchController` with `index` and `search` actions
- [ ] Build search form with Hotwire (Turbo Frame for results)
- [ ] Build artifact detail view
- [ ] Write system specs for key UI flows

### Acceptance Criteria

- [ ] Dashboard shows knowledge base health summary
- [ ] Project page shows collector runs with status and timing
- [ ] Search page returns and displays results from hybrid search
- [ ] Artifact detail shows content, provenance, and linked chunks
- [ ] All new UI follows existing Hotwire/Turbo patterns
- [ ] `bin/rspec` passes

### Notes / Risks

- Use existing Phlex components if available, otherwise standard ERB (match existing views).
- Keep the UI minimal — this is for operators, not end users.
- Search results should link to the artifact detail view for drill-down.

---

## Issue 16: Staleness Detection and Re-collection Triggers

**Labels:** `knowledge`, `agents`
**Depends on:** Issues 4, 9

### Background / Why

Knowledge becomes stale when the codebase changes. When HEAD advances or relevant files change, the system must detect staleness and trigger re-collection. This keeps the knowledge base fresh without requiring manual intervention.

### Scope

**In scope:**

- `Knowledge::Staleness::Detector` service — compares current HEAD to last collected version
- File-level staleness: detect which files changed between versions (git diff)
- Mark affected artifacts as stale
- Trigger re-collection for stale projects (via GoodJob job)
- Integration with `GitHubPollWorkflow` — after fetching issues, check if knowledge needs refresh
- Configurable staleness threshold (e.g., re-collect if HEAD is > N commits ahead)

**Out of scope:**

- Real-time streaming updates
- Per-file incremental collection (collect at project-version granularity)

### Proposed Design

**Detection flow:**

```
1. Get current HEAD SHA for project
2. Get last ProjectVersion with completed CollectorRuns
3. If HEAD == last version SHA → not stale, skip
4. If HEAD != last version SHA:
   a. git diff --name-only <last_sha>..<head_sha>
   b. For each changed file, find artifacts with matching scope_path
   c. Mark those artifacts as stale
   d. Enqueue RunCollectorsJob for the project
```

**Integration with polling workflow:**
Add a `CheckKnowledgeStalenessActivity` to `GitHubPollWorkflow` that runs after issue fetching:

```ruby
# In GitHubPollWorkflow, after fetch_issues:
run_activity(Activities::CheckKnowledgeStalenessActivity,
  { project_id: project_id }, timeout: 30)
```

### Implementation Tasks

- [ ] Create `app/services/knowledge/staleness/detector.rb`
- [ ] Implement git diff integration for file-change detection
- [ ] Add bulk staleness marking (update artifacts where scope_path matches changed files)
- [ ] Create `Activities::CheckKnowledgeStalenessActivity`
- [ ] Integrate into `GitHubPollWorkflow`
- [ ] Add `KNOWLEDGE_STALENESS_THRESHOLD` ENV config (default: 1 commit)
- [ ] Write specs for detector with mock git operations

### Acceptance Criteria

- [ ] Detector identifies stale artifacts when HEAD advances
- [ ] Only artifacts for changed files are marked stale (not the entire project)
- [ ] Re-collection is triggered automatically when staleness is detected
- [ ] Polling workflow checks staleness on each cycle
- [ ] No duplicate collection runs for the same version (idempotency from Issue 4)
- [ ] `bin/rspec` passes

### Notes / Risks

- git diff requires the repo to be cloned. Use `WorktreeService.current_commit_sha` and git operations on the bare repo.
- Staleness detection should be fast (~100ms). Don't clone the repo for this — use the existing bare repo.
- Consider rate-limiting re-collection: max once per 5 minutes per project to avoid thrashing during rapid commits.

---

## Issue 17: Postgres Full-Text and Trigram Search Setup

**Labels:** `knowledge`, `infra`
**Depends on:** Issue 2

### Background / Why

The retrieval layer (Issue 10) needs Postgres-native text search capabilities for exact and lexical queries. This issue enables `pg_trgm` for fuzzy identifier matching and `tsvector` for full-text search on chunk content, providing the Postgres side of hybrid retrieval.

### Scope

**In scope:**

- Enable `pg_trgm` extension
- Add `tsvector` generated column on `knowledge_chunks.content`
- Add GIN index on the tsvector column
- Add GIN trigram index on `knowledge_artifacts.identifier`
- Helper scopes on models for text search

**Out of scope:**

- Search service implementation (Issue 10)
- Custom text search dictionaries

### Proposed Design

**Migration:**

```ruby
class AddTextSearchToKnowledge < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"

    # Full-text search on chunk content
    add_column :knowledge_chunks, :content_tsvector, :tsvector
    add_index :knowledge_chunks, :content_tsvector, using: :gin

    # Auto-update tsvector via trigger
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE TRIGGER knowledge_chunks_tsvector_update
          BEFORE INSERT OR UPDATE OF content ON knowledge_chunks
          FOR EACH ROW EXECUTE FUNCTION
          tsvector_update_trigger(content_tsvector, 'pg_catalog.english', content);
        SQL
      end
      dir.down do
        execute "DROP TRIGGER IF EXISTS knowledge_chunks_tsvector_update ON knowledge_chunks;"
      end
    end

    # Trigram index for fuzzy identifier matching
    add_index :knowledge_artifacts, :identifier, using: :gin, opclass: :gin_trgm_ops,
              name: "index_knowledge_artifacts_on_identifier_trgm"
  end
end
```

**Model scopes:**

```ruby
# KnowledgeChunk
scope :full_text_search, ->(query) {
  where("content_tsvector @@ plainto_tsquery('english', ?)", query)
    .order(Arel.sql("ts_rank(content_tsvector, plainto_tsquery('english', #{connection.quote(query)})) DESC"))
}

# KnowledgeArtifact
scope :identifier_like, ->(query) {
  where("identifier % ?", query)  # trigram similarity
    .order(Arel.sql("similarity(identifier, #{connection.quote(query)}) DESC"))
}
```

### Implementation Tasks

- [ ] Create migration to enable `pg_trgm` extension
- [ ] Create migration to add `tsvector` column, trigger, and GIN indexes
- [ ] Add `full_text_search` scope to `KnowledgeChunk`
- [ ] Add `identifier_like` scope to `KnowledgeArtifact`
- [ ] Write specs for both scopes with test data
- [ ] Verify indexes are used via `EXPLAIN ANALYZE` in specs

### Acceptance Criteria

- [ ] `pg_trgm` extension is enabled
- [ ] `tsvector` column auto-updates on chunk insert/update
- [ ] Full-text search returns ranked results
- [ ] Trigram search finds fuzzy matches on identifiers
- [ ] GIN indexes are used (verified via explain plans)
- [ ] `bin/rspec` passes

### Notes / Risks

- The `tsvector` trigger uses `'pg_catalog.english'` dictionary. Code identifiers may not tokenize well with English stemming. Consider `'pg_catalog.simple'` if search quality is poor for code.
- `pg_trgm` similarity threshold defaults to 0.3. May need tuning for identifier matching.

---

## Issue 18: Internal Architecture Docs and Runbook

**Labels:** `knowledge`, `docs`

### Background / Why

The knowledge base adds significant new infrastructure (Qdrant, collectors, embedding pipeline, retrieval). Engineering docs and a runbook ensure the team can operate, debug, and extend the system.

### Scope

**In scope:**

- `docs/KNOWLEDGE_BASE.md` — architecture overview, data model, collector framework, retrieval modes
- `docs/rdrs/RDR-019-knowledge-base.md` — formal RDR for the knowledge base architecture decisions
- `docs/runbooks/knowledge-base.md` — operational runbook: health checks, rebuild, troubleshooting, cost monitoring
- Update `docs/DATA_MODEL.md` with new tables
- Update `docs/ARCHITECTURE.md` with knowledge base layer

**Out of scope:**

- User-facing documentation
- API reference (auto-generate later)

### Implementation Tasks

- [ ] Write `docs/KNOWLEDGE_BASE.md`
- [ ] Write `docs/rdrs/RDR-019-knowledge-base.md` (status: Final)
- [ ] Write `docs/runbooks/knowledge-base.md`
- [ ] Update `docs/DATA_MODEL.md` with: `project_versions`, `collector_runs`, `knowledge_artifacts`, `knowledge_chunks`, `knowledge_links`, `decision_records`, `decision_record_links`
- [ ] Update `docs/ARCHITECTURE.md` to include knowledge base layer
- [ ] Add Qdrant to the infrastructure diagram

### Acceptance Criteria

- [ ] Architecture doc explains the full knowledge pipeline (collect → store → embed → retrieve)
- [ ] RDR documents the "why" for key decisions (Qdrant over pgvector, Postgres as canonical store, redaction-first)
- [ ] Runbook covers: how to rebuild a project's knowledge, how to check Qdrant health, how to debug stale knowledge, how to monitor embedding costs
- [ ] DATA_MODEL.md is updated with all new tables and their relationships
- [ ] `bin/lint` passes on all markdown files

### Notes / Risks

- Write docs as issues are completed, not all at the end. This issue tracks the final review and gaps.
- RDR-019 should reference this issue collection as the implementation plan.

---

## Issue 19: Knowledge Collection Trigger on Project Creation

**Labels:** `knowledge`, `agents`
**Depends on:** Issues 4, 9

### Background / Why

Agents benefit most when semantic context is available from their first run. When a project is added to Paid, a knowledge collection should be automatically triggered so that by the time the first issue is labeled, the knowledge base is populated.

### Scope

**In scope:**

- Trigger `RunCollectorsJob` after project creation (callback or explicit call in project import flow)
- Ensure collection waits for the initial clone to complete
- Add a `knowledge_status` field to `Project` (e.g., `pending`, `collecting`, `ready`, `failed`)
- Show knowledge status on the project dashboard

**Out of scope:**

- Blocking agent runs on knowledge collection (agents should work without knowledge, just with degraded context)

### Proposed Design

**Project callback:**

```ruby
# In Project model or Projects::Import service
after_create_commit :enqueue_knowledge_collection

def enqueue_knowledge_collection
  RunCollectorsJob.perform_later(id)
end
```

**Status field:**

```
knowledge_status: string(50) DEFAULT 'pending'
  -- pending | collecting | ready | failed | stale
```

### Implementation Tasks

- [ ] Add `knowledge_status` column to `projects` table
- [ ] Add project creation hook to enqueue `RunCollectorsJob`
- [ ] Update `RunCollectorsJob` to set project `knowledge_status` (collecting → ready/failed)
- [ ] Show knowledge status badge on project dashboard
- [ ] Write specs for the creation → collection flow

### Acceptance Criteria

- [ ] New project creation triggers knowledge collection
- [ ] Project shows `knowledge_status` in the UI
- [ ] Collection failure doesn't block project functionality
- [ ] `bin/rspec` passes

### Notes / Risks

- The initial clone may take a while for large repos. `RunCollectorsJob` should retry if the clone isn't ready yet (use a `retry_on` with backoff).
- Don't block the project creation response on knowledge collection — it's a background job.

---

## Issue 20: Safe Defaults and Security Hardening

**Labels:** `knowledge`, `security`
**Depends on:** Issues 8, 13

### Background / Why

The knowledge base handles code content that may contain secrets, and communicates with Qdrant (a network service). This issue ensures safe defaults are in place: Qdrant API key auth in production, minimal Qdrant payloads, redaction pipeline is mandatory (not optional), and access control on knowledge APIs.

### Scope

**In scope:**

- Qdrant API key authentication in non-development environments
- Validate that Qdrant payloads never contain `content` text (enforce at `PointSync` level)
- Ensure redaction pipeline cannot be bypassed (embedding pipeline refuses unscanned chunks)
- Access control on knowledge APIs (require authenticated user + project access via Pundit)
- Rate limiting on knowledge search API
- Secrets: `QDRANT_API_KEY` in Rails credentials, not ENV in production

**Out of scope:**

- Qdrant TLS (depends on deployment topology)
- Network-level isolation beyond existing Docker networks

### Proposed Design

**Payload validation in PointSync:**

```ruby
FORBIDDEN_PAYLOAD_KEYS = %w[content text body secret password token].freeze

def validate_payload!(payload)
  forbidden = payload.keys.map(&:to_s) & FORBIDDEN_PAYLOAD_KEYS
  raise SecurityError, "Forbidden payload keys: #{forbidden}" if forbidden.any?
end
```

**Mandatory redaction:**

```ruby
# In Knowledge::Embeddings::Pipeline
def process_chunk(chunk)
  raise "Chunk not scanned for redaction" unless chunk.redaction_scanned?
  # ...
end
```

**Pundit policy:**

```ruby
class KnowledgeSearchPolicy < ApplicationPolicy
  def search?
    user.has_role?(:member, record.project) || user.has_role?(:admin, record.project)
  end
end
```

### Implementation Tasks

- [ ] Add `QDRANT_API_KEY` to Rails credentials for production
- [ ] Enforce API key in `QdrantClient` when `Rails.env.production?`
- [ ] Add payload validation in `PointSync.upsert_chunk!`
- [ ] Add `redaction_scanned_at` column to `knowledge_chunks`
- [ ] Enforce redaction scan in embedding pipeline
- [ ] Create `KnowledgeSearchPolicy` Pundit policy
- [ ] Add rate limiting to `Api::KnowledgeSearchController` (e.g., 60 req/min)
- [ ] Write security-focused specs (payload validation, unauthorized access, bypass attempts)
- [ ] Add Brakeman custom check or annotation for knowledge APIs

### Acceptance Criteria

- [ ] Qdrant requires API key in production
- [ ] Attempting to upsert a payload with `content` key raises `SecurityError`
- [ ] Attempting to embed a chunk that hasn't been redaction-scanned raises an error
- [ ] Unauthenticated knowledge search requests return 401
- [ ] Users can only search projects they have access to
- [ ] Rate limiting is active on search endpoints
- [ ] `bin/rspec` and `bin/audit` pass

### Notes / Risks

- `redaction_scanned_at` column means we can audit when the last scan happened. If redaction patterns are updated, chunks scanned before the update should be re-scanned.
- Rate limiting: use `Rack::Attack` or a simple `ActiveSupport::Cache`-based counter. Don't over-engineer.

---

## Dependency Graph

```
Issue 1: Qdrant Infrastructure
Issue 2: Postgres Schema ─────────────────────┐
Issue 17: PG Full-Text Setup (depends: 2)     │
Issue 13: Redaction Pipeline (depends: 2)      │
Issue 4: Collector Framework (depends: 2) ─────┤
Issue 12: Decision Records (depends: 2)        │
Issue 14: Provenance/Audit (depends: 4)        │
Issue 3: Qdrant Collections (depends: 1, 2)    │
Issue 6: Static Collectors (depends: 4)        │
Issue 7: Analytical Collectors (depends: 4)    │
Issue 8: Embedding Pipeline (depends: 2, 3) ───┤
Issue 9: Containerized Runners (depends: 4)    │
Issue 5: Thin Slice (depends: 1,2,3,4,8) ─────┤
Issue 10: Retrieval API (depends: 3,5,8,17)    │
Issue 11: Agent Context Bundle (depends: 10)   │
Issue 16: Staleness Detection (depends: 4, 9)  │
Issue 15: Admin UI (depends: 5, 10)            │
Issue 19: Project Creation Trigger (depends: 4)│
Issue 20: Security Hardening (depends: 8, 13)  │
Issue 18: Docs (independent, write as you go)  │
```

**Suggested implementation order:**

1. **Foundation (parallel):** Issues 1, 2, 13, 17, 18 (start docs)
2. **Framework:** Issues 3, 4, 12
3. **Collectors + Embedding:** Issues 6, 7, 8
4. **Thin Slice:** Issue 5
5. **Retrieval + Integration:** Issues 10, 11
6. **Operations:** Issues 9, 14, 16, 19
7. **Hardening + UI:** Issues 15, 20, 18 (finalize docs)

---

## Label Definitions

| Label | Description |
|-------|-------------|
| `knowledge` | Knowledge base feature work |
| `qdrant` | Qdrant vector database integration |
| `agents` | Agent workflow integration |
| `security` | Security, redaction, access control |
| `observability` | Logging, audit, monitoring |
| `infra` | Infrastructure, Docker, deployment |
| `docs` | Documentation |
