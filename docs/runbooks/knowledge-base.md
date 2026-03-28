# Knowledge Base Operational Runbook

## Quick Reference

| Task | Command / Endpoint |
|------|-------------------|
| Check Qdrant health | `Paid.qdrant_client.healthy?` |
| List collections | `Paid.qdrant_client.collections.list` |
| Rebuild PostgreSQL project knowledge (collector artifacts only) | `Knowledge::CollectorRunner.new(project: project, commit_sha: commit_sha).run` |
| Check embedding backlog | `KnowledgeChunk.needs_embedding.count` |
| View recent audit events | `KnowledgeAuditEvent.for_project(project).ordered.limit(20)` |
| Rebuild Qdrant collection | `Knowledge::Qdrant::CollectionManager.new(project: project).rebuild_schema!` |

**Note**: `Knowledge::CollectorRunner#run` only rebuilds PostgreSQL-side knowledge (collector artifacts, chunks, etc.). It does *not* generate embeddings or sync points to Qdrant; run the embedding pipeline separately if you need to fully restore semantic retrieval.

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

Knowledge::CollectorRunner.new(project: project, commit_sha: commit_sha).run

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
  commit_sha: version.commit_sha
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

**Resolution**: The `KnowledgeAuditRetentionJob` handles pruning. Verify it's running in the GoodJob dashboard. Default retention is configurable — check the job implementation for the current threshold.

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
