# RDR-018: Semantic Code Search

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
- Trigger deep codebase analysis when a project is added

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

### Integration Options Evaluated

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

Bypass Arcaneum's CLI and use Qdrant and MeiliSearch directly via their Ruby client gems. Build indexing in Ruby; use Ruby gems for search at request time.

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
**Cons**: Must generate embeddings separately (external API or local model); must build own chunking (doesn't leverage Arcaneum's AST chunking)

#### Option C: Hybrid (Best of Both)

Use Arcaneum CLI for **indexing** (leverages AST chunking, PDF processing) via background jobs, and Ruby gems for **searching** (low-latency, native integration).

**Pros**: Best indexing quality; fast searching; clean separation
**Cons**: Most complex setup; requires both Python and Ruby tooling; two systems to maintain

#### Option D: PostgreSQL pgvector

Skip dedicated search infrastructure. Use PostgreSQL's pgvector extension for vector search alongside existing full-text search capabilities.

```ruby
# Gemfile
gem "neighbor"  # Rails pgvector integration

# Search
CodeChunk.nearest_neighbors(:embedding, query_embedding, distance: :cosine).limit(10)
```

**Pros**: Single database; no additional infrastructure; Rails-native; simpler deployment
**Cons**: Must implement own chunking/indexing; no AST-aware parsing; PostgreSQL handles vectors but isn't specialized for it; lower-dimensional support; would serve as transitional technology before eventually migrating to dedicated search infrastructure

### Key Discoveries

1. **Arcaneum is CLI-first with no API**: Integration from Rails requires either subprocess calls or bypassing it to use backends directly. This is a significant friction point.

2. **The real value is in indexing, not searching**: Arcaneum's AST-aware code chunking and multi-format support (PDF, markdown, code) are its differentiators. The search backends (Qdrant, MeiliSearch) are commodities with good Ruby support.

3. **Embedding generation is the gap**: Any Ruby-native approach needs a strategy for generating embeddings. Options include external APIs (OpenAI, Cohere), local models via Python subprocess, or the ruby-llm gem's embedding support.

4. **pgvector is transitional**: While pgvector provides vector search without new infrastructure, it is not a specialized vector database. It would only serve as a stepping stone before migrating to Qdrant when scale or quality demands it. Better to build for the target architecture from the start.

5. **Corpus-per-project maps well**: Arcaneum's corpus abstraction aligns with Paid's project model. Each project would have its own Qdrant collection and MeiliSearch index, preventing cross-contamination.

6. **Deep initial indexing is critical**: Agents benefit most when semantic context is available from their very first run on a project. Triggering a comprehensive index on project creation ensures this.

## Proposed Solution

### Recommendation: Qdrant + MeiliSearch (Direct Integration)

Use purpose-built search infrastructure from the start:

- **Qdrant** for semantic (vector) search — purpose-built vector database with high-dimensional support, filtering, and payload storage
- **MeiliSearch** for full-text search — typo-tolerant, faceted search with native Rails integration
- **Ruby gems** (`qdrant-ruby`, `meilisearch-rails`) for search at request time
- **External API** for embedding generation (OpenAI text-embedding-3-large or equivalent via ruby-llm)
- **Deep indexing** triggered automatically on project creation, with incremental updates on git push

This uses Option B (Direct Backend Integration) from the research findings. pgvector (Option D) was rejected as a transitional technology — it would only delay the eventual migration to dedicated search infrastructure while providing inferior search quality in the interim.

### Technical Design

```
┌─────────────────────────────────────────────────────────────┐
│                   SEMANTIC SEARCH LAYER                      │
│                                                             │
│  ┌────────────────────────┐  ┌───────────────────────────┐  │
│  │     INDEX PIPELINE     │  │      SEARCH SERVICE       │  │
│  │                        │  │                           │  │
│  │  1. Git clone/pull     │  │  Query → Embedding        │  │
│  │  2. Walk file tree     │  │  Embedding → Qdrant       │  │
│  │  3. Chunk by function  │  │  Query text → MeiliSearch │  │
│  │  4. Generate embeddings│  │  Merge + rank results     │  │
│  │  5. Store in Qdrant    │  │  Context → Agent prompt   │  │
│  │  6. Index in MeiliSearch│ │                           │  │
│  │                        │  │                           │  │
│  │  Triggers:             │  │                           │  │
│  │  • Project creation    │  │                           │  │
│  │  • Git push webhook    │  │                           │  │
│  │  • Manual re-index     │  │                           │  │
│  │                        │  │                           │  │
│  │  (Background job via   │  │                           │  │
│  │   GoodJob)             │  │                           │  │
│  └────────────────────────┘  └───────────────────────────┘  │
│                                                             │
│  Vector Storage: Qdrant (one collection per project)        │
│  Full-text: MeiliSearch (one index per project)             │
│  Embeddings: External API (OpenAI/Cohere) or ruby-llm      │
└─────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Purpose-built tools**: Qdrant is designed for vector search with high-dimensional embeddings, filtering, and payload storage. MeiliSearch is designed for typo-tolerant full-text search. Both outperform general-purpose alternatives in their domains.
2. **No transitional technology**: pgvector would only be a stepping stone. Building directly on Qdrant avoids a future migration and provides better search quality from day one.
3. **Ruby-native search path**: Both `qdrant-ruby` and `meilisearch-rails` provide native Ruby clients, keeping the request-time search path in Ruby with no subprocess overhead.
4. **Docker-native deployment**: Both Qdrant and MeiliSearch run as Docker containers, fitting the existing infrastructure.
5. **Project-scoped isolation**: One Qdrant collection and one MeiliSearch index per project prevents cross-contamination and enables per-project management.
6. **Deep indexing on project creation**: A background job performs comprehensive initial indexing when a project is added, so agents have semantic context from their first run.

### Integration Point

Semantic search plugs into the agent execution workflow between issue fetching and agent invocation:

```ruby
# In AgentExecutionWorkflow
def execute(issue_id)
  issue = activity.fetch_issue(issue_id)
  project = issue.project

  # Retrieve relevant codebase context via Qdrant + MeiliSearch
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

**Pros**: Leverages all Arcaneum features including AST-aware chunking; minimal custom code

**Cons**: Python runtime dependency; subprocess overhead on every search; hard to test; fragile error handling; heavy dependencies (~1-2GB models)

**Reason for rejection**: Too much operational complexity. The Python dependency conflicts with the Ruby-centric stack. Arcaneum's indexing insights (AST-aware chunking) can be adopted in a Ruby implementation without depending on the full Python toolchain.

### Alternative 2: PostgreSQL pgvector

**Description**: Use PostgreSQL's pgvector extension for vector search alongside built-in full-text search. No new infrastructure required.

**Pros**: Single database; no additional services; Rails-native via `neighbor` gem; simpler deployment

**Cons**: pgvector is a general-purpose extension, not a specialized vector database. Lower-dimensional vector support, fewer filtering options, and weaker performance at scale compared to Qdrant. Would serve as a transitional technology requiring migration later.

**Reason for rejection**: pgvector would only be a stepping stone to Qdrant. Building directly on the target technology avoids a migration and provides better search quality from day one.

### Alternative 3: External Search Service (Algolia, Elastic)

**Description**: Use a managed search service for semantic and full-text search.

**Pros**: Managed infrastructure; proven at scale; good SDKs

**Cons**: Cost; data leaves the environment; vendor lock-in; may not support vector search well

**Reason for rejection**: Adds external dependency and cost for a feature that benefits from self-hosted control. Docker infrastructure already exists.

### Alternative 4: ChromaDB

**Description**: Use ChromaDB as the vector database instead of Qdrant.

**Pros**: Simple API; growing ecosystem; embeddable option

**Cons**: Python-centric (no official Ruby gem); less mature production deployment story; would require REST API calls from Ruby rather than a native client

**Reason for rejection**: Qdrant has a mature Ruby client (`qdrant-ruby`), better production deployment patterns, and richer filtering capabilities. ChromaDB could be reconsidered if a quality Ruby client emerges.

## Trade-offs and Consequences

### Positive Consequences

- **Faster agent context building**: Agents start with relevant codebase knowledge from their first run
- **Better code quality**: Agents can discover existing patterns and conventions
- **Institutional memory**: Knowledge persists across agent runs
- **Purpose-built search**: Qdrant and MeiliSearch each excel at their respective search modes
- **Deep initial indexing**: Project creation triggers comprehensive codebase analysis

### Negative Consequences

- **Additional infrastructure**: Two new services (Qdrant, MeiliSearch) to deploy and maintain
- **Embedding API cost**: Small cost per indexing operation (mitigated: only on file changes, incremental sync)
- **Index staleness**: Code changes require re-indexing (mitigated: trigger on git push/webhook)
- **Storage requirements**: Qdrant and MeiliSearch need dedicated storage (mitigated: prune on project deletion)

### Risks and Mitigations

- **Risk**: Semantic search doesn't meaningfully improve agent output quality
  **Mitigation**: A/B test with and without semantic context. Measure PR acceptance rates.

- **Risk**: Embedding quality is poor for code
  **Mitigation**: Use code-optimized embedding models (e.g., OpenAI text-embedding-3-large, jina-code). Benchmark with representative queries.

- **Risk**: Qdrant/MeiliSearch operational complexity
  **Mitigation**: Both services are mature, well-documented, and Docker-native. Paid already manages Docker services in development and production.

## Implementation Plan

### Prerequisites

- [ ] Evaluate embedding API options and costs (OpenAI vs Cohere vs local)
- [ ] Define chunking strategy for code files (function-level vs file-level)

### Step 1: Add Infrastructure

Add Qdrant and MeiliSearch to `docker-compose.yml`:

```yaml
services:
  qdrant:
    image: qdrant/qdrant:v1.13.2
    ports:
      - "6333:6333"
    volumes:
      - qdrant_data:/qdrant/storage

  meilisearch:
    image: getmeili/meilisearch:v1.13.0
    ports:
      - "7700:7700"
    environment:
      MEILI_MASTER_KEY: ${MEILISEARCH_MASTER_KEY}
    volumes:
      - meilisearch_data:/meili_data
```

### Step 2: Create Code Chunks Table

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
      t.string :language
      t.integer :start_line
      t.integer :end_line
      t.string :qdrant_point_id          # Reference to Qdrant point

      t.timestamps
      t.index [:project_id, :file_path, :identifier], unique: true
      t.index :content_hash
    end
  end
end
```

### Step 3: Implement Indexing Service

```ruby
# app/services/semantic_search/index_project.rb
module SemanticSearch
  class IndexProject
    include Servo::Service

    input do
      attribute :project, Dry::Types["any"]
    end

    def call
      ensure_qdrant_collection!
      ensure_meilisearch_index!

      walk_files(project.repo_path).each do |file_path|
        chunks = chunk_file(file_path)
        chunks.each { |chunk| index_chunk(chunk) }
      end
    end

    private

    # Walks the file tree, yielding indexable source files.
    # Skips symlinks, vendor directories, binary files, and dotfiles.
    # Validates real paths stay under the repo root to prevent symlink
    # traversal attacks in untrusted repositories.
    def walk_files(repo_path)
      root = File.realpath(repo_path)

      Dir.glob(File.join(root, "**", "*"))
         .select do |f|
           next false if File.symlink?(f)
           next false unless File.file?(f)

           real = File.realpath(f)
           real.start_with?("#{root}/") && indexable?(real)
         rescue Errno::ENOENT, Errno::EACCES
           false
         end
    end

    # Splits a source file into semantic chunks (function/class/module level).
    # Falls back to file-level chunking when AST parsing is unavailable.
    def chunk_file(file_path)
      content = File.read(file_path)
      language = detect_language(file_path)

      # TODO(#66): Implement AST-aware chunking via tree-sitter for
      # function/class-level granularity. For now, chunk at file level.
      [{
        path: file_path, id: file_path, type: "file",
        content: content, language: language,
        start_line: 1, end_line: content.lines.count
      }]
    end

    # Generates a vector embedding for the given text content.
    # Uses OpenAI's text-embedding-3-large (3072 dimensions).
    def generate_embedding(content)
      client = OpenAI::Client.new
      response = client.embeddings(
        parameters: {
          model: "text-embedding-3-large",
          input: content
        }
      )
      response.dig("data", 0, "embedding")
    end

    def ensure_meilisearch_index!
      meilisearch_index.update_settings(
        searchableAttributes: %w[content identifier file_path],
        filterableAttributes: %w[language chunk_type]
      )
    rescue MeiliSearch::ApiError => e
      raise unless e.message.include?("already exists")
    end

    def ensure_qdrant_collection!
      qdrant.collections.create(
        collection_name: collection_name,
        vectors: { size: 3072, distance: "Cosine" }  # text-embedding-3-large dimensions
      )
    rescue Qdrant::Error => e
      raise unless e.message.include?("already exists")
    end

    def index_chunk(chunk)
      hash = Digest::SHA256.hexdigest(chunk[:content])
      existing = CodeChunk.find_by(project: project, file_path: chunk[:path], identifier: chunk[:id])
      return if existing&.content_hash == hash  # Skip unchanged

      embedding = generate_embedding(chunk[:content])

      # Store vector in Qdrant
      point_id = SecureRandom.uuid
      qdrant.points.upsert(
        collection_name: collection_name,
        points: [{
          id: point_id,
          vector: embedding,
          payload: {
            file_path: chunk[:path],
            identifier: chunk[:id],
            chunk_type: chunk[:type],
            language: chunk[:language]
          }
        }]
      )

      # Index full text in MeiliSearch
      meilisearch_index.add_documents([{
        id: point_id,
        file_path: chunk[:path],
        identifier: chunk[:id],
        content: chunk[:content],
        language: chunk[:language]
      }])

      # Store metadata in PostgreSQL
      CodeChunk.upsert({
        project_id: project.id,
        file_path: chunk[:path],
        chunk_type: chunk[:type],
        identifier: chunk[:id],
        content: chunk[:content],
        content_hash: hash,
        language: chunk[:language],
        start_line: chunk[:start_line],
        end_line: chunk[:end_line],
        qdrant_point_id: point_id
      }, unique_by: [:project_id, :file_path, :identifier])
    end

    def collection_name = "project_#{project.id}"
    def qdrant = @qdrant ||= Qdrant::Client.new(url: ENV["QDRANT_URL"])
    def meilisearch_index = @meilisearch_index ||= MeiliSearch::Client.new(ENV["MEILISEARCH_URL"], ENV["MEILISEARCH_MASTER_KEY"]).index(collection_name)
  end
end
```

### Step 4: Implement Search Service

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

      # Semantic search via Qdrant
      vector_results = qdrant.points.search(
        collection_name: "project_#{project.id}",
        vector: embedding,
        limit: limit,
        with_payload: true
      )

      # Full-text search via MeiliSearch
      text_results = meilisearch_index.search(query, limit: limit)

      # Merge and deduplicate results, prioritizing semantic matches
      merge_results(vector_results, text_results)
    end

    private

    # Merges vector (semantic) and full-text results into a single ranked list.
    # Deduplicates by point ID. Semantic matches are prioritized: a result
    # appearing in both sets gets a boosted score; remaining text-only results
    # are appended after all semantic results.
    def merge_results(vector_results, text_results)
      text_ids = Set.new(text_results["hits"]&.map { |h| h["id"] })
      seen = Set.new
      merged = []

      # Semantic results first (highest relevance)
      vector_results.dig("result")&.each do |point|
        id = point["id"]
        next if seen.include?(id)
        seen.add(id)

        merged << {
          id: id,
          score: point["score"],
          payload: point["payload"],
          source: text_ids.include?(id) ? :both : :semantic
        }
      end

      # Append text-only results
      text_results["hits"]&.each do |hit|
        next if seen.include?(hit["id"])
        seen.add(hit["id"])

        merged << {
          id: hit["id"],
          score: nil,
          payload: hit.slice("file_path", "identifier", "content"),
          source: :full_text
        }
      end

      merged.first(limit)
    end

    def qdrant = @qdrant ||= Qdrant::Client.new(url: ENV["QDRANT_URL"])
    def meilisearch_index = @meilisearch_index ||= MeiliSearch::Client.new(ENV["MEILISEARCH_URL"], ENV["MEILISEARCH_MASTER_KEY"]).index("project_#{project.id}")
  end
end
```

### Step 5: Trigger Indexing on Project Creation

```ruby
# app/jobs/index_project_job.rb
class IndexProjectJob < ApplicationJob
  queue_as :default

  def perform(project_id)
    project = Project.find(project_id)
    SemanticSearch::IndexProject.call(project: project)
  end
end

# Wire into Projects::Import or model callback:
# IndexProjectJob.perform_later(project.id)
```

### Step 6: Integrate with Agent Workflow

Modify `Prompts::BuildForIssue` to include semantic search results as codebase context in the agent prompt.

### Files to Create

- `db/migrate/xxx_create_code_chunks.rb`
- `app/models/code_chunk.rb`
- `app/services/semantic_search/index_project.rb`
- `app/services/semantic_search/query.rb`
- `app/jobs/index_project_job.rb`
- `config/initializers/qdrant.rb`
- `config/initializers/meilisearch.rb`

### Files to Modify

- `docker-compose.yml` (add Qdrant and MeiliSearch services)
- `Gemfile` (add `qdrant-ruby` and `meilisearch-rails` gems)
- `app/services/prompts/build_for_issue.rb` (inject semantic context)
- `app/temporal/workflows/agent_execution_workflow.rb` (add search step)
- `app/services/projects/import.rb` or model callback (trigger indexing on project creation)

### Dependencies

- `qdrant-ruby` gem for Qdrant API client
- `meilisearch-rails` gem for MeiliSearch Rails integration
- Qdrant Docker image (`qdrant/qdrant`)
- MeiliSearch Docker image (`getmeili/meilisearch`)
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

5. **Scenario**: New project added to Paid
   **Expected**: Deep indexing job triggered automatically; semantic context available for first agent run

### Performance Validation

- Index a 10K-file repository in < 30 minutes (background job)
- Semantic search returns results in < 500ms
- Embedding generation cost < $0.01 per file

## References

### Requirements & Standards

- Paid VISION.md — Bitter Lesson, computation over hand-crafted knowledge
- Paid ARCHITECTURE.md — System design and technology stack

### Dependencies

- [Arcaneum](https://github.com/cwensel/arcaneum) — Semantic search CLI tool (investigated, indexing insights adopted)
- [qdrant-ruby](https://github.com/patterns-ai-core/qdrant-ruby) — Qdrant API client for Ruby
- [meilisearch-rails](https://github.com/meilisearch/meilisearch-rails) — MeiliSearch Rails integration
- [Qdrant](https://qdrant.tech/) — Purpose-built vector database
- [MeiliSearch](https://www.meilisearch.com/) — Full-text search engine

### Research Resources

- [Arcaneum GitHub repository](https://github.com/cwensel/arcaneum)
- [Qdrant documentation](https://qdrant.tech/documentation/)
- [MeiliSearch Rails Quick Start](https://www.meilisearch.com/docs/guides/ruby_on_rails_quick_start)

## Notes

- Arcaneum's strongest value proposition is its AST-aware code chunking. Consider adopting this chunking approach in the Ruby indexing service rather than depending on the full Python toolchain.
- The embedding model choice significantly affects search quality for code. Code-specific models (like jina-code or OpenAI's text-embedding-3-large) outperform general-purpose models.
- Consider exposing semantic search in the UI so users can verify index quality and search relevance before relying on it for agent execution.
- Deep indexing on project creation is critical — agents should have semantic context available from their first run, not after a manual re-index.
- Arcaneum's "store" feature (agent memory) could inspire a similar capability for persisting knowledge gained during agent runs, building institutional memory across runs.
