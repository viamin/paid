# RDR-018: Semantic Code Search with Arcaneum

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-02-16
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: #66 (Look into using arcaneum for semantic data)
- **Related Tests**: N/A (investigation phase)

## Problem Statement

Paid agents operate on codebases they have no prior understanding of. Each agent run starts from scratch—reading issue descriptions, exploring the repository, and building mental models before writing any code. This is wasteful:

- **Repeated discovery**: Every agent run re-explores the same codebase structure
- **Shallow context**: Agents miss patterns, conventions, and related code in large repositories
- **No institutional memory**: Knowledge gained during one run is lost for the next
- **Prompt limitations**: Context windows limit how much codebase knowledge can be injected

A semantic search layer would let agents query indexed project knowledge—architecture, patterns, conventions, related code—rather than discovering it from scratch each time.

Requirements:

- Index project source code, documentation, and reference materials
- Support semantic (vector) search for conceptual queries ("how does auth work?")
- Support full-text search for exact matches ("def authenticate_user")
- Integrate with agent execution workflow to provide codebase context
- Scale to multiple projects without cross-contamination

## Context

### Background

The "Bitter Lesson" principle (documented in VISION.md) suggests we should invest in systems that leverage computation over hand-crafted knowledge. Semantic search aligns with this—rather than manually curating codebase summaries, we index everything and let vector similarity surface what's relevant.

[Arcaneum](https://github.com/cwensel/arcaneum) was identified as a potential tool for this capability. It provides dual-index semantic and full-text search over code and documentation.

### Technical Environment

- Rails 8 application with PostgreSQL
- Docker-based container isolation for agent execution
- Temporal.io for workflow orchestration
- GoodJob for background job processing
- Agent execution already uses Docker containers with git worktrees

## Research Findings

### Investigation Process

1. Analyzed Arcaneum's architecture, capabilities, and limitations
2. Evaluated integration approaches for a Rails application
3. Assessed alternative solutions using Ruby-native tools
4. Considered deployment complexity and operational overhead

### Arcaneum Analysis

**What it is**: A Python CLI tool that indexes code, documentation, and PDFs into dual search backends (Qdrant for vector search, MeiliSearch for full-text search). It supports 165+ programming languages via tree-sitter AST parsing and provides incremental sync with content hashing.

**Key capabilities**:

- Semantic search via Qdrant vector database with configurable embedding models
- Full-text search via MeiliSearch with typo tolerance
- Git-aware source code indexing with AST-based chunking
- PDF processing with OCR support
- "Corpus" abstraction for organizing indexed content
- Incremental sync (only re-indexes changed content)
- Claude Code plugin with slash commands

**Embedding models**: Eight pre-configured models including jina-code (optimized for code, 32K context) and stella (general-purpose for documentation).

**Architecture**:

```
┌──────────────────────────────────────────────┐
│              Arcaneum CLI (Python)            │
│                                              │
│  arc corpus sync   →  Index code/docs        │
│  arc search semantic → Vector similarity     │
│  arc search text   →  Full-text matching     │
│  arc store         →  Agent memory           │
└──────────┬──────────────────┬────────────────┘
           │                  │
           ▼                  ▼
    ┌─────────────┐   ┌──────────────┐
    │   Qdrant    │   │ MeiliSearch  │
    │  (Vectors)  │   │ (Full-text)  │
    └─────────────┘   └──────────────┘
```

**Limitations**:

- Python-only (no Ruby SDK, no REST API, CLI-only interface)
- Requires Python 3.12+ runtime
- Requires Docker for Qdrant and MeiliSearch services
- Not published to PyPI (requires git clone + editable install)
- Heavy dependencies (~1-2GB for embedding models)
- No multi-user or production deployment patterns documented

### Integration Options

#### Option A: CLI Subprocess (Simplest)

Call Arcaneum via shell commands from Rails.

```ruby
# Example: semantic search via subprocess
output = `arc search semantic "auth pattern" --corpus MyProject --format json`
results = JSON.parse(output)
```

**Pros**: Uses full Arcaneum functionality; minimal integration code
**Cons**: Subprocess overhead; Python runtime dependency in production; hard to test; error handling is fragile

#### Option B: Direct Backend Integration (Recommended)

Bypass Arcaneum's CLI and use Qdrant and MeiliSearch directly via their Ruby client gems. Let Arcaneum handle indexing (as a background task) and use Ruby gems for search at request time.

Ruby gems available:

- `qdrant-ruby` — Official Qdrant API wrapper, Rails 2.3–8.0 compatible
- `meilisearch-rails` — Official MeiliSearch integration with ActiveRecord callbacks

```ruby
# Search via qdrant-ruby
client = Qdrant::Client.new(url: ENV["QDRANT_URL"])
client.points.search(
  collection_name: "project_#{project.id}",
  vector: embedding,
  limit: 10
)
```

**Pros**: Native Ruby; better performance; easier testing; no Python in hot path
**Cons**: Must generate embeddings separately (external API or local model); doesn't leverage Arcaneum's AST chunking for indexing

#### Option C: Hybrid (Best of Both)

Use Arcaneum CLI for **indexing** (leverages AST chunking, PDF processing) via background jobs, and Ruby gems for **searching** (low-latency, native integration).

```ruby
# Indexing (background job, uses Arcaneum CLI)
class IndexProjectJob < ApplicationJob
  def perform(project_id)
    project = Project.find(project_id)
    system("arc", "corpus", "sync", project.name, project.repo_path)
  end
end

# Searching (request time, uses Ruby gems)
class SemanticSearch::Query
  def call(query, project:)
    embedding = generate_embedding(query)
    qdrant.points.search(
      collection_name: "project_#{project.id}",
      vector: embedding,
      limit: 10
    )
  end
end
```

**Pros**: Best indexing quality; fast searching; clean separation
**Cons**: Most complex setup; requires both Python and Ruby tooling; two systems to maintain

#### Option D: PostgreSQL pgvector (Alternative)

Skip Arcaneum entirely. Use PostgreSQL's pgvector extension for vector search alongside existing full-text search capabilities.

```ruby
# Gemfile
gem "neighbor"  # Rails pgvector integration

# Migration
enable_extension "vector"
add_column :code_chunks, :embedding, :vector, limit: 1536

# Search
CodeChunk.nearest_neighbors(:embedding, query_embedding, distance: :cosine).limit(10)
```

**Pros**: Single database; no additional infrastructure; Rails-native; simpler deployment; pgvector is mature and well-supported
**Cons**: Must implement own chunking/indexing; no AST-aware parsing; PostgreSQL handles vectors but isn't specialized for it at scale

### Key Discoveries

1. **Arcaneum is CLI-first with no API**: Integration from Rails requires either subprocess calls or bypassing it to use backends directly. This is a significant friction point.

2. **The real value is in indexing, not searching**: Arcaneum's AST-aware code chunking and multi-format support (PDF, markdown, code) are its differentiators. The search backends (Qdrant, MeiliSearch) are commodities with good Ruby support.

3. **Embedding generation is the gap**: Any Ruby-native approach needs a strategy for generating embeddings. Options include external APIs (OpenAI, Cohere), local models via Python subprocess, or the ruby-llm gem's embedding support.

4. **pgvector is a viable simpler path**: For a Rails app already using PostgreSQL, pgvector + the `neighbor` gem provides vector search without additional infrastructure. Combined with PostgreSQL's built-in full-text search, this covers both search modes with zero new services.

5. **Corpus-per-project maps well**: Arcaneum's corpus abstraction aligns with Paid's project model. Each project would have its own corpus, preventing cross-contamination.

## Proposed Solution

### Recommendation: Phased Approach

Start with **Option D (pgvector)** for simplicity, with the architecture designed to swap in specialized backends later if needed.

**Phase 1 — pgvector Foundation** (Recommended starting point):

- Add pgvector extension to PostgreSQL
- Create `code_chunks` table with vector embeddings
- Implement basic indexing service using git tree walking + embedding API
- Provide semantic search to agents via context injection in prompts
- Use PostgreSQL full-text search for exact matching

**Phase 2 — Enhanced Indexing** (If Phase 1 proves valuable):

- Integrate Arcaneum CLI as a background indexing pipeline for better code chunking
- Continue using pgvector/PostgreSQL for search (keep it simple)
- Add PDF and documentation indexing

**Phase 3 — Specialized Backends** (If scale demands):

- Migrate to Qdrant + MeiliSearch if PostgreSQL becomes a bottleneck
- Use Ruby gems for search, Arcaneum for indexing
- Evaluate whether the complexity is justified by usage patterns

### Technical Design

```
┌─────────────────────────────────────────────────────────────┐
│                   SEMANTIC SEARCH LAYER                      │
│                                                             │
│  ┌────────────────────────┐  ┌───────────────────────────┐  │
│  │     INDEX PIPELINE     │  │      SEARCH SERVICE       │  │
│  │                        │  │                           │  │
│  │  1. Git clone/pull     │  │  Query → Embedding        │  │
│  │  2. Walk file tree     │  │  Embedding → pgvector     │  │
│  │  3. Chunk by function  │  │  Results → Context        │  │
│  │  4. Generate embeddings│  │  Context → Agent prompt   │  │
│  │  5. Store in pgvector  │  │                           │  │
│  │                        │  │  Also: PG full-text search│  │
│  │  (Background job via   │  │  for exact code matches   │  │
│  │   GoodJob)             │  │                           │  │
│  └────────────────────────┘  └───────────────────────────┘  │
│                                                             │
│  Storage: PostgreSQL + pgvector extension                   │
│  Embeddings: External API (OpenAI/Cohere) or ruby-llm      │
└─────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **pgvector first**: Avoids new infrastructure. PostgreSQL is already in the stack. The `neighbor` gem provides clean Rails integration.
2. **Arcaneum for later**: Its AST-aware chunking is valuable but not critical for an MVP. Basic file/function chunking is sufficient to prove the concept.
3. **Phased approach**: Validates whether semantic search improves agent performance before investing in complex infrastructure.
4. **Embedding via API**: Avoids local model hosting complexity. Cost is minimal for indexing (one-time per file change).

### Integration Point

Semantic search would plug into the agent execution workflow between issue fetching and agent invocation:

```ruby
# In AgentExecutionWorkflow
def execute(issue_id)
  issue = activity.fetch_issue(issue_id)
  project = issue.project

  # NEW: Retrieve relevant codebase context
  context = activity.search_codebase(
    query: issue.title + "\n" + issue.body,
    project: project,
    limit: 20
  )

  # Include semantic context in agent prompt
  prompt = activity.build_prompt(issue: issue, codebase_context: context)

  container = activity.provision_container(project: project)
  result = activity.run_agent(container: container, prompt: prompt)
  # ...
end
```

## Alternatives Considered

### Alternative 1: Full Arcaneum Integration (CLI Subprocess)

**Description**: Use Arcaneum end-to-end via subprocess calls for both indexing and searching.

**Pros**: Leverages all Arcaneum features; minimal custom code

**Cons**: Python runtime dependency; subprocess overhead on every search; hard to test; fragile error handling; heavy dependencies (~1-2GB models)

**Reason for deferral**: Too much operational complexity for an unproven feature. The Python dependency conflicts with the Ruby-centric stack.

### Alternative 2: Qdrant + MeiliSearch (Direct)

**Description**: Deploy Qdrant and MeiliSearch as services, use Ruby gems to interact with them directly.

**Pros**: Purpose-built search infrastructure; Ruby-native clients available

**Cons**: Two additional services to deploy and maintain; more infrastructure complexity; operational overhead

**Reason for deferral**: Premature optimization. pgvector handles the initial use case. Migrate if scale demands.

### Alternative 3: External Search Service (Algolia, Elastic)

**Description**: Use a managed search service for semantic and full-text search.

**Pros**: Managed infrastructure; proven at scale; good SDKs

**Cons**: Cost; data leaves the environment; vendor lock-in; may not support vector search well

**Reason for rejection**: Adds external dependency and cost for a feature that may not prove valuable. Self-hosted is preferred given the existing Docker infrastructure.

## Trade-offs and Consequences

### Positive Consequences

- **Faster agent context building**: Agents start with relevant codebase knowledge
- **Better code quality**: Agents can discover existing patterns and conventions
- **Institutional memory**: Knowledge persists across agent runs
- **Minimal new infrastructure**: pgvector uses existing PostgreSQL
- **Upgrade path**: Architecture supports migrating to specialized backends

### Negative Consequences

- **Embedding API cost**: Small cost per indexing operation (mitigated: only on file changes)
- **Index staleness**: Code changes require re-indexing (mitigated: trigger on git push/webhook)
- **Storage growth**: Embeddings consume database space (mitigated: prune on project deletion)

### Risks and Mitigations

- **Risk**: Semantic search doesn't meaningfully improve agent output quality
  **Mitigation**: A/B test with and without semantic context. Measure PR acceptance rates.

- **Risk**: Embedding quality is poor for code
  **Mitigation**: Use code-optimized embedding models (e.g., OpenAI text-embedding-3-large, Cohere embed-v3). Benchmark with representative queries.

- **Risk**: pgvector performance degrades at scale
  **Mitigation**: Phase 3 migration path to Qdrant is designed in. Monitor query latency.

## Implementation Plan

### Prerequisites

- [ ] Evaluate embedding API options and costs (OpenAI vs Cohere vs local)
- [ ] Benchmark pgvector query performance with realistic data volumes
- [ ] Define chunking strategy for code files (function-level vs file-level)

### Step-by-Step Implementation (Phase 1)

#### Step 1: Add pgvector Extension

```ruby
# db/migrate/xxx_enable_pgvector.rb
class EnablePgvector < ActiveRecord::Migration[8.0]
  def change
    enable_extension "vector"
  end
end
```

#### Step 2: Create Code Chunks Table

```ruby
# db/migrate/xxx_create_code_chunks.rb
class CreateCodeChunks < ActiveRecord::Migration[8.0]
  def change
    create_table :code_chunks do |t|
      t.references :project, null: false, foreign_key: true
      t.string :file_path, null: false
      t.string :chunk_type, null: false  # function, class, module, file
      t.string :identifier               # function/class name
      t.text :content, null: false
      t.string :content_hash, null: false # SHA256 for incremental sync
      t.vector :embedding, limit: 1536    # Dimension depends on model
      t.integer :start_line
      t.integer :end_line

      t.timestamps
      t.index [:project_id, :file_path, :identifier], unique: true
      t.index :content_hash
    end
  end
end
```

#### Step 3: Implement Indexing Service

```ruby
# app/services/semantic_search/index_project.rb
module SemanticSearch
  class IndexProject
    include Servo::Service

    input do
      attribute :project, Dry::Types["any"]
    end

    def call
      walk_files(project.repo_path).each do |file_path|
        chunks = chunk_file(file_path)
        chunks.each { |chunk| index_chunk(chunk) }
      end
    end
  end
end
```

#### Step 4: Implement Search Service

```ruby
# app/services/semantic_search/query.rb
module SemanticSearch
  class Query
    include Servo::Service

    input do
      attribute :query, Dry::Types["strict.string"]
      attribute :project, Dry::Types["any"]
      attribute :limit, Dry::Types["strict.integer"].default(10)
    end

    def call
      embedding = generate_embedding(query)
      CodeChunk
        .where(project: project)
        .nearest_neighbors(:embedding, embedding, distance: :cosine)
        .limit(limit)
    end
  end
end
```

#### Step 5: Integrate with Agent Workflow

Modify `Prompts::BuildForIssue` to include semantic search results as codebase context in the agent prompt.

### Files to Create

- `db/migrate/xxx_enable_pgvector.rb`
- `db/migrate/xxx_create_code_chunks.rb`
- `app/models/code_chunk.rb`
- `app/services/semantic_search/index_project.rb`
- `app/services/semantic_search/query.rb`
- `app/jobs/index_project_job.rb`

### Files to Modify

- `Gemfile` (add `neighbor` gem)
- `app/services/prompts/build_for_issue.rb` (inject semantic context)
- `app/temporal/workflows/agent_execution_workflow.rb` (add search step)

### Dependencies

- `neighbor` gem for pgvector Rails integration
- pgvector PostgreSQL extension
- Embedding API access (OpenAI or equivalent)

## Validation

### Testing Approach

1. Unit tests for chunking and indexing services
2. Integration tests for search accuracy with sample codebases
3. A/B test agent performance with and without semantic context
4. Measure PR acceptance rate delta

### Test Scenarios

1. **Scenario**: Agent working on auth-related issue
   **Expected**: Semantic search surfaces existing auth code, middleware, and tests

2. **Scenario**: Agent working on a new feature in a large codebase
   **Expected**: Search finds similar existing features and conventions

3. **Scenario**: Project re-indexed after code changes
   **Expected**: Only changed files are re-embedded (incremental sync)

4. **Scenario**: Search across project with 10K+ files
   **Expected**: Query completes in < 500ms

### Performance Validation

- Index a 10K-file repository in < 30 minutes (background job)
- Semantic search returns results in < 500ms
- Embedding generation cost < $0.01 per file

## References

### Requirements & Standards

- Paid VISION.md — Bitter Lesson, computation over hand-crafted knowledge
- Paid ARCHITECTURE.md — System design and technology stack

### Dependencies

- [Arcaneum](https://github.com/cwensel/arcaneum) — Semantic search CLI tool (investigated)
- [neighbor](https://github.com/ankane/neighbor) — pgvector Rails integration
- [qdrant-ruby](https://github.com/patterns-ai-core/qdrant-ruby) — Qdrant API client (Phase 3)
- [meilisearch-rails](https://github.com/meilisearch/meilisearch-rails) — MeiliSearch integration (Phase 3)
- [pgvector](https://github.com/pgvector/pgvector) — PostgreSQL vector extension

### Research Resources

- [Arcaneum GitHub repository](https://github.com/cwensel/arcaneum)
- [pgvector documentation](https://github.com/pgvector/pgvector)
- [MeiliSearch Rails Quick Start](https://www.meilisearch.com/docs/guides/ruby_on_rails_quick_start)

## Notes

- Arcaneum's strongest value proposition is its AST-aware code chunking and multi-format indexing. Consider extracting this logic (or building a simpler Ruby equivalent) rather than depending on the full Python toolchain.
- The embedding model choice significantly affects search quality for code. Code-specific models (like jina-code or OpenAI's text-embedding-3-large) outperform general-purpose models.
- Consider exposing semantic search in the UI so users can verify index quality and search relevance before relying on it for agent execution.
- Future: Arcaneum's "store" feature (agent memory) could be used to persist knowledge gained during agent runs, building institutional memory across runs.
