# RDR-003: Database Selection (PostgreSQL)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Database migration tests, model specs

## Problem Statement

Paid requires a database to store:

1. **Multi-tenant data**: Accounts, users, projects, issues
2. **Configuration as data**: Prompts, versions, model preferences, style guides
3. **Metrics and analytics**: Token usage, quality scores, A/B test results
4. **Audit logs**: Agent runs, workflow states, cost tracking
5. **Encrypted secrets**: GitHub tokens (encrypted at rest)

Requirements:

- Strong consistency (financial-grade for cost tracking)
- JSON support for flexible schema (labels, settings, metadata)
- Full-text search capability (for prompt content, logs)
- Encryption at rest
- Mature Rails integration
- Compatibility with Temporal.io (can share or separate)
- Support for GoodJob (PostgreSQL-backed job queues)

## Context

### Background

Paid follows the "Bitter Lesson" principle: configuration is data, not code. This means the database is central to how Paid operates—prompts, model selections, and quality metrics all live in the database and evolve over time.

The database must handle:

- Write-heavy workloads (agent run logs, token usage)
- Read-heavy workloads (dashboard queries, prompt resolution)
- Complex queries (A/B test analytics, quality aggregations)
- Time-series data (metrics over time)

### Technical Environment

- Framework: Rails 8+ (see RDR-001)
- Workflow: Temporal.io (see RDR-002)
- Deployment: Self-hosted initially, Docker-based
- Expected scale: 100K-1M rows in agent_runs table within first year

## Research Findings

### Investigation Process

1. Evaluated PostgreSQL features for application requirements
2. Compared with MySQL, SQLite, MongoDB
3. Analyzed Temporal.io database requirements
4. Reviewed Rails 8 database integrations
5. Assessed JSON/JSONB capabilities for flexible schema

### Key Discoveries

**PostgreSQL Advantages for Paid:**

1. **JSONB Support**: First-class JSON with indexing

   ```sql
   -- Store flexible settings
   CREATE TABLE projects (
     id BIGSERIAL PRIMARY KEY,
     labels JSONB DEFAULT '{}',
     settings JSONB DEFAULT '{}'
   );

   -- Index specific JSON paths
   CREATE INDEX idx_projects_labels ON projects USING GIN (labels);

   -- Query JSON efficiently
   SELECT * FROM projects WHERE labels->>'plan' = 'paid-plan';
   ```

2. **Array Types**: Native arrays for tags, scopes

   ```sql
   CREATE TABLE github_tokens (
     id BIGSERIAL PRIMARY KEY,
     scopes TEXT[] NOT NULL
   );

   -- Query array contents
   SELECT * FROM github_tokens WHERE 'repo' = ANY(scopes);
   ```

3. **Full-Text Search**: Built-in search without external service

   ```sql
   -- Search prompt templates
   SELECT * FROM prompt_versions
   WHERE to_tsvector('english', template) @@ plainto_tsquery('implement feature');
   ```

4. **Window Functions**: Complex analytics for A/B testing

   ```sql
   -- Calculate running averages for A/B test
   SELECT
     variant_id,
     quality_score,
     AVG(quality_score) OVER (
       PARTITION BY variant_id
       ORDER BY created_at
       ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
     ) as rolling_avg
   FROM quality_metrics;
   ```

5. **Temporal Compatibility**: Temporal supports PostgreSQL as persistence store

   ```yaml
   # Temporal configuration
   persistence:
     default:
       driver: "sql"
       sql:
         pluginName: "postgres12"
         databaseName: "temporal"
   ```

6. **Rails 8 Integration**: Native support for multiple databases

   ```ruby
   # config/database.yml
   production:
     primary:
       adapter: postgresql
       database: paid_production
     cache:
       adapter: postgresql
       database: paid_production_cache
       migrations_paths: db/cache_migrate
     cable:
       adapter: postgresql
       database: paid_production_cable
       migrations_paths: db/cable_migrate
   ```

**PostgreSQL vs. Alternatives:**

| Feature | PostgreSQL | MySQL | SQLite | MongoDB |
|---------|------------|-------|--------|---------|
| JSONB | Native, indexed | JSON (limited) | JSON (extension) | Native |
| Full-text search | Built-in | Built-in | Extension | Built-in |
| Arrays | Native | No | No | Native |
| ACID compliance | Full | Full | Full | Configurable |
| Temporal support | Yes | Yes | No | No |
| Rails integration | Excellent | Excellent | Good | Via Mongoid |
| Encryption at rest | Yes | Yes | Limited | Yes |
| GoodJob support | Yes | Yes | Yes | No |

**Temporal Database Sharing:**

Temporal can use the same PostgreSQL instance as Paid, but in separate databases:

```
PostgreSQL Instance
├── paid_development (Rails app)
├── paid_test (Rails tests)
├── paid_production (Rails app)
└── temporal (Temporal server)
```

This simplifies infrastructure while maintaining isolation.

**Encryption at Rest:**

Rails 8 provides application-level encryption:

```ruby
class GithubToken < ApplicationRecord
  encrypts :token, deterministic: false
end
```

PostgreSQL also supports disk-level encryption via TDE or filesystem encryption.

## Proposed Solution

### Approach

Use **PostgreSQL 15+** as the single database technology for:

- Rails application data
- GoodJob job queues
- Temporal persistence (separate database on same instance)

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      POSTGRESQL ARCHITECTURE                                 │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                      PostgreSQL Instance                                 ││
│  │                                                                          ││
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐           ││
│  │  │ paid_production │ │   temporal      │ │   (replicas)    │           ││
│  │  │                 │ │                 │ │                 │           ││
│  │  │ • accounts      │ │ • executions    │ │ • read queries  │           ││
│  │  │ • users         │ │ • activities    │ │ • analytics     │           ││
│  │  │ • projects      │ │ • timers        │ │                 │           ││
│  │  │ • prompts       │ │ • visibility    │ │                 │           ││
│  │  │ • agent_runs    │ │                 │ │                 │           ││
│  │  │ • good_job_*    │ │                 │ │                 │           ││
│  │  └─────────────────┘ └─────────────────┘ └─────────────────┘           ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│              ┌─────────────────────┴─────────────────────┐                  │
│              ▼                                           ▼                  │
│  ┌─────────────────────┐                    ┌─────────────────────┐        │
│  │    Rails App        │                    │   Temporal Server   │        │
│  │                     │                    │                     │        │
│  │ • Active Record     │                    │ • Workflow history  │        │
│  │ • GoodJob           │                    │ • Activity tasks    │        │
│  │ • Solid Cache       │                    │ • Timer schedules   │        │
│  └─────────────────────┘                    └─────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **JSONB**: Perfect for flexible configuration (labels, settings, metadata)
2. **Analytics**: Window functions enable A/B test analysis in SQL
3. **Temporal**: Native support simplifies deployment
4. **Rails**: Excellent Active Record integration
5. **Single technology**: Reduces operational complexity
6. **Proven**: Battle-tested at scale, well-understood failure modes

### Implementation Example

```ruby
# db/migrate/001_create_accounts.rb
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.jsonb :settings, default: {}, null: false
      t.string :plan, default: 'free'

      t.timestamps
    end

    add_index :accounts, :slug, unique: true
    add_index :accounts, :settings, using: :gin
  end
end

# db/migrate/010_create_prompt_versions.rb
class CreatePromptVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :prompt_versions do |t|
      t.references :prompt, null: false, foreign_key: true
      t.integer :version, null: false
      t.text :template, null: false
      t.jsonb :variables, default: []
      t.text :system_prompt
      t.text :change_notes
      t.string :created_by

      t.timestamp :created_at, null: false
    end

    add_index :prompt_versions, [:prompt_id, :version], unique: true

    # Full-text search on template
    execute <<-SQL
      CREATE INDEX idx_prompt_versions_template_search
      ON prompt_versions
      USING GIN (to_tsvector('english', template));
    SQL
  end
end

# app/models/prompt_version.rb
class PromptVersion < ApplicationRecord
  belongs_to :prompt

  scope :search_template, ->(query) {
    where("to_tsvector('english', template) @@ plainto_tsquery(?)", query)
  }
end
```

## Alternatives Considered

### Alternative 1: MySQL

**Description**: Use MySQL as the primary database

**Pros**:

- Excellent Rails integration
- Temporal support
- Wide hosting availability
- Good performance

**Cons**:

- JSON support less mature than PostgreSQL JSONB
- No native array types
- Full-text search less powerful
- JSONB indexing not as flexible

**Reason for rejection**: PostgreSQL's JSONB support is superior for configuration-as-data pattern. The ability to index JSON paths efficiently is valuable for Paid's query patterns.

### Alternative 2: MongoDB

**Description**: Use MongoDB for flexible schema storage

**Pros**:

- Native JSON/BSON
- Flexible schema
- Horizontal scaling

**Cons**:

- No Temporal support
- Different data model (requires Mongoid instead of Active Record)
- Weaker ACID guarantees by default
- Separate technology to operate

**Reason for rejection**: Temporal requires a relational database. Using MongoDB would mean running both MongoDB and PostgreSQL, adding operational complexity.

### Alternative 3: SQLite

**Description**: Use SQLite for simplicity

**Pros**:

- Zero configuration
- File-based (easy backup)
- Good Rails support via GoodJob

**Cons**:

- No Temporal support
- Limited concurrent writes
- No JSON indexing
- Not production-ready for this scale

**Reason for rejection**: SQLite doesn't scale for Paid's requirements and Temporal doesn't support it.

### Alternative 4: Separate Databases

**Description**: Use PostgreSQL for Rails and a separate datastore for time-series/analytics

**Pros**:

- Optimized storage per use case
- Could use TimescaleDB for metrics

**Cons**:

- Operational complexity
- Data consistency challenges
- More infrastructure to manage

**Reason for rejection**: PostgreSQL handles all requirements adequately. Can add specialized storage later if needed, but premature optimization to start.

## Trade-offs and Consequences

### Positive Consequences

- **Single database technology**: Simplified operations, one backup strategy
- **JSONB flexibility**: Schema can evolve without migrations for some fields
- **Integrated analytics**: Complex queries in SQL without external tools
- **Temporal compatibility**: Shared PostgreSQL instance simplifies deployment
- **Mature ecosystem**: pgAdmin, pg_dump, monitoring tools well established

### Negative Consequences

- **PostgreSQL expertise required**: Team must understand PostgreSQL-specific features
- **Vertical scaling initially**: Horizontal scaling more complex than NoSQL
- **JSON query learning curve**: JSONB queries have specific syntax

### Risks and Mitigations

- **Risk**: PostgreSQL becomes bottleneck under high write load
  **Mitigation**: Implement table partitioning for large tables (token_usages, agent_run_logs). Add read replicas for dashboard queries.

- **Risk**: JSONB queries become slow with large datasets
  **Mitigation**: Create appropriate GIN indexes on frequently queried JSON paths. Monitor query performance with pg_stat_statements.

- **Risk**: Database grows large with log data
  **Mitigation**: Implement data retention policies. Consider partitioning by time for log tables.

## Implementation Plan

### Prerequisites

- [ ] PostgreSQL 15+ installed or Docker image available
- [ ] Sufficient disk space for expected data volume
- [ ] Backup strategy defined

### Step-by-Step Implementation

#### Step 1: Configure PostgreSQL

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: paid
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/init-db.sql
    ports:
      - "5432:5432"
```

```sql
-- init-db.sql
CREATE DATABASE paid_development;
CREATE DATABASE paid_test;
CREATE DATABASE temporal;

-- Enable extensions
\c paid_development
CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- For trigram similarity
CREATE EXTENSION IF NOT EXISTS btree_gin; -- For GIN indexes on regular columns
```

#### Step 2: Configure Rails Database

```yaml
# config/database.yml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  host: <%= ENV.fetch("DATABASE_HOST") { "localhost" } %>
  username: <%= ENV.fetch("DATABASE_USERNAME") { "paid" } %>
  password: <%= ENV.fetch("DATABASE_PASSWORD") { "" } %>

development:
  <<: *default
  database: paid_development

test:
  <<: *default
  database: paid_test

production:
  <<: *default
  database: paid_production
```

#### Step 3: Configure Temporal Database

```yaml
# temporal-config.yaml (for Temporal server)
persistence:
  default:
    driver: "sql"
    sql:
      pluginName: "postgres12"
      databaseName: "temporal"
      connectAddr: "postgres:5432"
      connectProtocol: "tcp"
      user: "paid"
      password: "${POSTGRES_PASSWORD}"
```

#### Step 4: Create Core Tables

Run Rails migrations in order per DATA_MODEL.md.

### Files to Modify

- `config/database.yml` - Database configuration
- `docker-compose.yml` - PostgreSQL service definition
- `db/migrate/` - Migration files for all tables
- `.env` - Database credentials

### Dependencies

- PostgreSQL 15+ (or 16 recommended)
- `pg` gem (Rails default)
- `pg_search` gem (optional, for advanced full-text search)

## Validation

### Testing Approach

1. Migration tests (all migrations run cleanly)
2. Model validation tests
3. Query performance tests with realistic data volumes
4. Concurrent write tests

### Test Scenarios

1. **Scenario**: Create account with JSONB settings
   **Expected Result**: Settings stored and queryable via JSON operators

2. **Scenario**: Search prompt templates by content
   **Expected Result**: Full-text search returns relevant results

3. **Scenario**: Calculate A/B test statistics
   **Expected Result**: Window functions correctly compute rolling averages

4. **Scenario**: 100 concurrent agent runs writing logs
   **Expected Result**: No deadlocks, acceptable write throughput

### Performance Validation

- Dashboard queries complete in < 100ms
- Agent run log writes handle 100 writes/second
- JSONB queries with GIN index < 10ms for typical patterns
- Connection pool adequately sized (monitor wait times)

### Security Validation

- Database not exposed to public internet
- Connection uses SSL in production
- Credentials stored securely (Rails credentials or environment)
- Application-level encryption for sensitive fields (GithubToken.token)

## References

### Requirements & Standards

- Paid DATA_MODEL.md - Schema design
- [The Bitter Lesson](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf) - Configuration as data

### Dependencies

- [PostgreSQL Documentation](https://www.postgresql.org/docs/16/)
- [PostgreSQL JSONB](https://www.postgresql.org/docs/16/datatype-json.html)
- [Rails Database Guide](https://guides.rubyonrails.org/active_record_postgresql.html)
- [Temporal Persistence](https://docs.temporal.io/self-hosted-guide/postgresql)

### Research Resources

- PostgreSQL JSONB performance benchmarks
- PostgreSQL partitioning strategies
- Rails multi-database configuration

## Notes

- Monitor slow queries with pg_stat_statements from day one
- Consider read replicas when dashboard query load increases
- TimescaleDB extension is available if time-series queries become a bottleneck
- pg_partman can automate table partitioning for log tables
