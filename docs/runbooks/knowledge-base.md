# Knowledge Base Operational Runbook

## Quick Reference

| Task | Command / Endpoint |
|------|-------------------|
| Check Qdrant health | `Paid.qdrant_client.healthy?` |
| List collections | `Paid.qdrant_client.collections.list` |
| Rebuild PostgreSQL project knowledge (collector artifacts only) | `Knowledge::CollectorRunner.new(project: project, commit_sha: commit_sha, committed_at: committed_at).run` |
| Check embedding backlog | `KnowledgeChunk.needs_embedding.count` |
| View recent audit events | `KnowledgeAuditEvent.for_project(project).ordered.limit(20)` |
| Rebuild Qdrant collection | `Knowledge::Qdrant::CollectionManager.new(project: project).rebuild_schema!` |

**Note**: `Knowledge::CollectorRunner#run` only rebuilds PostgreSQL-side knowledge (collector artifacts, chunks, etc.). It does *not* generate embeddings or sync points to Qdrant; run the embedding pipeline separately if you need to fully restore semantic retrieval. When invoking it, you should pass a `committed_at` timestamp (and optionally `branch`) for the `ProjectVersion`; omitting `committed_at` disables cross-version stale marking and can leave artifacts from older versions incorrectly marked as `active`.

## Health Checks

### Qdrant Health

```ruby
# Rails console
Paid.qdrant_client.healthy?
# => true

# Check specific collection
Paid.qdrant_client.collections.get(collection_name: "project_42")
```

**Expected**: Returns collection info with `points_count`, `vectors_count`, and `status: "green"`.

**If unhealthy**:

1. Check Qdrant container is running: `docker compose ps qdrant`
2. Check Qdrant logs: `docker compose logs qdrant`
3. Verify `QDRANT_URL` environment variable is correct
4. Check network connectivity between Rails and Qdrant on `paid_internal`

### PostgreSQL Knowledge Tables

```ruby
# Check table row counts
{
  project_versions: ProjectVersion.count,
  collector_runs: CollectorRun.count,
  artifacts: KnowledgeArtifact.count,
  chunks: KnowledgeChunk.count,
  links: KnowledgeLink.count,
  audit_events: KnowledgeAuditEvent.count
}
```

### Collector Status

```ruby
# Recent collector runs with failures
CollectorRun.failed.order(created_at: :desc).limit(10)
  .pluck(:id, :collector_type, :error_message, :created_at)

# Collectors stuck in running state (possible zombie)
CollectorRun.running.where("started_at < ?", 1.hour.ago)
```

## Rebuilding Project Knowledge

### Full Rebuild (Qdrant + PostgreSQL)

Use when Qdrant data is lost or corrupted, or when you need to re-collect from scratch.

```ruby
project = Project.find(id)

# Step 1: Drop and recreate Qdrant collection
Knowledge::Qdrant::CollectionManager.new(project: project).rebuild_schema!

# Step 2: Re-collect knowledge for the current commit
# Clear existing collector runs so CollectorRunner does not skip completed runs
worktree = project.worktrees.find_by(default: true) || project.worktrees.first
commit_sha = `git -C #{worktree.path} rev-parse HEAD`.strip
project_version = ProjectVersion.find_by(project: project, commit_sha: commit_sha)

if project_version
  # destroy_all cascades: CollectorRun → KnowledgeArtifact → KnowledgeChunk → KnowledgeLink
  CollectorRun.where(project_version: project_version).destroy_all
end

committed_at = `git -C #{worktree.path} show -s --format=%cI #{commit_sha}`.strip
Knowledge::CollectorRunner.new(project: project, commit_sha: commit_sha, committed_at: committed_at).run

# Step 3: Reset embedding_model so active chunks are picked up by the pipeline
KnowledgeChunk.active.where(project: project).update_all(embedding_model: nil)

# Step 4: Re-embed all active chunks
Knowledge::Embeddings::Pipeline.call(project: project)
```

### Qdrant-Only Rebuild

Use when PostgreSQL data is intact but Qdrant needs re-syncing. Note that because
embeddings (vectors) are not stored in PostgreSQL, Qdrant cannot be resynced
without re-embedding the chunks.

```ruby
project = Project.find(id)
manager = Knowledge::Qdrant::CollectionManager.new(project: project)

# Drop and recreate collection schema in Qdrant
manager.rebuild_schema!

# Reset embedding_model so active chunks are picked up by the pipeline
KnowledgeChunk.active.where(project: project).update_all(embedding_model: nil)

# Re-embed all active chunks for this project and push them to Qdrant
# (this will recompute vectors; there is no "Qdrant-only" sync without re-embedding)
Knowledge::Embeddings::Pipeline.call(project: project)
```

### Single Collector Re-run

Use when one collector's data seems incorrect.

```ruby
project = Project.find(id)
version = project.project_versions.order(created_at: :desc).first

# Delete the old collector run (cascades to artifacts and chunks)
CollectorRun.find_by(
  project_version: version,
  collector_type: "symbol_index"
)&.destroy

# Re-run just that collector
runner = Knowledge::CollectorRunner.new(
  project: project,
  commit_sha: version.commit_sha,
  committed_at: version.committed_at
)
runner.run
```

## Troubleshooting

### Stale Knowledge

**Symptom**: Agents receive outdated codebase context that doesn't match current code.

**Diagnosis**:

```ruby
project = Project.find(id)

# Check latest version
latest = project.project_versions.order(created_at: :desc).first
puts "Latest version: #{latest.commit_sha} (#{latest.created_at})"

# Check if collectors ran for latest version
latest.collector_runs.pluck(:collector_type, :status, :completed_at)

# Check for active artifacts from old versions
old_active = KnowledgeArtifact.active
  .joins(collector_run: :project_version)
  .where.not(project_versions: { id: latest.id })
  .where(project: project)
  .count
puts "Active artifacts from old versions: #{old_active}"
```

**Resolution**:

1. If collectors haven't run for the latest version, trigger a collection run
2. If old artifacts are still active, the stale-marking step may have failed — re-run the full pipeline
3. Check `RunCollectorsJob` for queued/failed jobs in GoodJob dashboard

### Missing Embeddings

**Symptom**: Semantic search returns no results, but exact search works.

**Diagnosis**:

```ruby
project = Project.find(id)

# Chunks needing embedding
pending = KnowledgeChunk.for_project(project).needs_embedding.count
embedded = KnowledgeChunk.for_project(project).embeddable.count
puts "Pending: #{pending}, Embedded: #{embedded}"

# Check Qdrant point count
info = Paid.qdrant_client.collections.get(
  collection_name: "project_#{project.id}"
)
puts "Qdrant points: #{info.dig('result', 'points_count')}"
```

**Resolution**:

1. If chunks are pending, run the embedding pipeline: `Knowledge::Embeddings::Pipeline.call(project: project)`
2. If chunks are marked embedded in PostgreSQL (e.g., `embedding_model` is set) but Qdrant is missing points, run the Qdrant-only rebuild (see above)
3. Check for embedding API errors in the logs: search for `embedding_error` or `Knowledge::Embeddings`

### Qdrant Collection Missing

**Symptom**: Search fails with collection not found error.

**Resolution**:

```ruby
project = Project.find(id)
Knowledge::Qdrant::CollectionManager.new(project: project).ensure_collection!
```

This is idempotent — safe to run even if the collection already exists.

### Collector Failures

**Symptom**: `CollectorRun` records show `status: "failed"`.

**Diagnosis**:

```ruby
CollectorRun.failed.order(created_at: :desc).limit(5).each do |run|
  puts "#{run.collector_type}: #{run.error_message}"
  puts "  Version: #{run.project_version.commit_sha}"
  puts "  Started: #{run.started_at}"
end
```

**Common causes**:

- **Timeout**: Collector took too long (check `duration_ms` on successful runs for baseline)
- **Missing tool**: Collector depends on a CLI tool not available in the environment
- **Parse error**: Source file has syntax that the collector can't handle
- **Permission error**: File not readable in the repo checkout

**Resolution**: Fix the underlying issue and re-run. Individual collector failures don't block other collectors.

### Audit Event Volume

**Symptom**: `knowledge_audit_events` table growing large.

**Diagnosis**:

```ruby
# Events per day over the last week
KnowledgeAuditEvent
  .where("created_at > ?", 7.days.ago)
  .group("DATE(created_at)")
  .count
```

**Resolution**: The `KnowledgeAuditRetentionJob` handles pruning. Verify it's running in the GoodJob dashboard. Retention is currently fixed at 90 days (see `KnowledgeAuditRetentionJob::RETENTION_PERIOD`).

## Monitoring Embedding Costs

### Tracking Usage

Embedding costs are tracked through audit events with `event_type: "chunk_embedded"`.

```ruby
# Embeddings generated in the last 24 hours
recent = KnowledgeAuditEvent
  .by_event_type("chunk_embedded")
  .since(24.hours.ago)
  .count
puts "Chunks embedded (24h): #{recent}"

# Per-project breakdown
KnowledgeAuditEvent
  .by_event_type("chunk_embedded")
  .since(24.hours.ago)
  .group(:project_id)
  .count
```

### Cost Estimation

OpenAI text-embedding-3-large pricing (as of 2026):

- ~$0.00013 per 1K tokens
- Average chunk: ~200-500 tokens
- Estimated cost per chunk: ~$0.00003-$0.00007

```ruby
# Estimate monthly cost for a project
project = Project.find(id)
monthly_chunks = KnowledgeAuditEvent
  .for_project(project)
  .by_event_type("chunk_embedded")
  .since(30.days.ago)
  .count
estimated_cost = monthly_chunks * 0.00005  # ~$0.05 per 1K chunks
puts "Estimated monthly embedding cost: $#{'%.2f' % estimated_cost}"
```

### Cost Control

- **Content-hash deduplication** prevents re-embedding unchanged content
- **Incremental updates** only process new/changed chunks
- **Batch processing** reduces API overhead
- Monitor the `needs_embedding` backlog to detect unexpected spikes

## Qdrant Maintenance

### Storage

```ruby
# Check collection storage
project = Project.find(id)
info = Paid.qdrant_client.collections.get(
  collection_name: "project_#{project.id}"
)
puts info.dig("result", "points_count")
```

Qdrant data is stored in the `qdrant-data` Docker volume. Monitor disk usage on the Docker host.

### Backup

Qdrant data is derived from PostgreSQL. The simplest backup strategy is to ensure PostgreSQL backups are current — Qdrant can always be rebuilt.

For faster recovery, Qdrant snapshots can be created via its REST API:

```bash
curl -X POST "http://localhost:6333/collections/project_42/snapshots"
```

### Cleanup on Project Deletion

The `QdrantCollectionCleanupJob` runs when a project is deleted, dropping its Qdrant collection. Verify this job is registered in the project deletion flow.

## Retroactive Physical Redaction (Scrub Workflow)

The pre-embedding redaction pipeline (`Knowledge::Embeddings::Pipeline`) only
scrubs content *before* it is embedded. When a new redaction pattern is added
to `config/knowledge/redaction_patterns.yml` after content has already been
indexed, or when an operator needs to retroactively purge sensitive material
from an already-embedded codebase, use the scrub workflow.

The scrub workflow is implemented by `Knowledge::Redaction::Scrubber` and
`Knowledge::Redaction::Reembed`. It runs in three stages:

1. **Scan** — re-runs `Knowledge::Redaction::Redactor` against every active
   chunk in the project and finds content that matches redaction patterns but
   has not yet been scrubbed.
2. **PostgreSQL scrub** — clears or replaces matched content with typed
   placeholders, updates `content_hash`, and flips the chunk to `redacted`
   (or keeps it `active` when only partial redaction applies).
3. **Qdrant cleanup** — deletes affected points in batches so semantic search
   cannot surface the removed content. When the number of scrubbed chunks
   exceeds `KNOWLEDGE_SCRUB_COLLECTION_REBUILD_THRESHOLD` (default: 500), the
   workflow instead calls `Knowledge::Qdrant::CollectionManager#rebuild_schema!`
   to drop and recreate the collection, then queues `EmbedChunksJob` to
   re-embed everything from PostgreSQL.

Every stage emits `KnowledgeAuditEvent` records (`chunks_scrubbed`,
`chunk_redacted`, `qdrant_collection_scrubbed`) so operators can audit what
was scrubbed, when, and by whom.

### Operator Workflow

The fastest path is the `knowledge:redact:scrub` rake task:

```bash
# Dry-run: preview what would be scrubbed without writing changes
bin/rails 'knowledge:redact:scrub[123]' DRY_RUN=true ACTOR_ID=42

# Live scrub for project 123, attributed to operator 42
bin/rails 'knowledge:redact:scrub[123]' ACTOR_ID=42

# Only re-embed previously scrubbed chunks from the last 24 hours
bin/rails 'knowledge:redact:reembed[123]' SINCE='2026-05-01T00:00:00Z'

# Re-embed an explicit list of chunk UUIDs
bin/rails 'knowledge:redact:reembed[123]' CHUNK_IDS='<uuid1>,<uuid2>'
```

Programmatic invocation (e.g. from a custom rake task or a Rails console
session):

```ruby
project = Project.find(123)

# Stage 1 + 2: scrub + Qdrant cleanup
scrub_result = Knowledge::Redaction::Scrubber.new(
  project: project,
  qdrant_client: Paid.qdrant_client,
  actor: { type: "operator", id: "42" }
).call

scrub_result.scrubbed_chunks          # chunks physically scrubbed in Postgres
scrub_result.deleted_qdrant_points    # Qdrant points removed
scrub_result.qdrant_collection_rebuilt # true when threshold-driven rebuild ran

# Stage 3: re-embed partially redacted chunks (those still active with a
# prior embedding). Uses the project's configured embedding provider.
generator = Knowledge::Embeddings::ProxyGenerator.new(
  project: project,
  provider_configs: Knowledge::RunnerConfiguration.for_embedding_candidate_runners(project: project),
  containerize: true
)

reembed_result = Knowledge::Redaction::Reembed.new(
  project: project,
  generator: generator,
  actor: { type: "operator", id: "42" }
).call

reembed_result.reembedded_count # active chunks whose embeddings were refreshed
```

To scope the scrub to a subset of the project, pass `scope_filter:`:

```ruby
Knowledge::Redaction::Scrubber.new(
  project: project,
  qdrant_client: Paid.qdrant_client,
  scope_filter: { scope_path: "app/controllers/users_controller.rb" }
).call
```

The supported `scope_filter` keys are:

- `knowledge_artifact_id:` — limit to a single artifact.
- `scope_path:` — limit to artifacts sharing a `scope_path` (typically a file).

### Safety Notes

- `Scrubber` is idempotent: re-running it skips chunks whose content has
  already been scrubbed because the redactor returns no changes for already
  redacted text.
- Set `dry_run: true` (or `DRY_RUN=true`) to preview scrub counts without
  writing to PostgreSQL, Qdrant, or the audit log. The dry-run summary is
  emitted as a structured log line (`knowledge.audit.dry_run_summary`)
  instead of a `KnowledgeAuditEvent` so the audit log stays free of
  speculative entries.
- When the bulk rebuild threshold trips, the collection is dropped via
  `rebuild_schema!`. Embeddings are *not* re-upserted automatically — you
  must run `Knowledge::Embeddings::Pipeline.call(project: project)` (or
  `EmbedChunksJob`) after the rebuild to restore semantic search. The rake
  task queues `EmbedChunksJob` automatically for you.
- Re-embedding requires an embedding provider configured for the project. If
  none is configured, `Knowledge::RunnerConfiguration.for_embedding_candidate_runners`
  returns an empty array and the re-embed step is a no-op (logged as
  `knowledge.embeddings.project_skipped`).
