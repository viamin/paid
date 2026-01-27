# RDR-005: Git Worktree Management

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Worktree service tests, cleanup job tests

## Problem Statement

Paid runs multiple AI agents in parallel, potentially on the same project. Each agent:

1. Needs a complete working copy of the repository
2. Creates a feature branch for its changes
3. Should not conflict with other agents working on the same project
4. Must have changes isolated until PR creation

Challenges:

- Multiple agents working on same repo simultaneously
- Each agent needs an independent working directory
- Storage efficiency (avoid full clones per agent)
- Cleanup of abandoned worktrees
- Branch management across agent runs

## Context

### Background

Git worktrees allow multiple working directories backed by a single repository. This is perfect for Paid's use case:

```
/workspaces/project-a/
├── .git/                         # Shared git database
├── main/                         # Main branch checkout
├── worktree-issue-123-abc/       # Agent 1's workspace
├── worktree-issue-456-def/       # Agent 2's workspace
└── worktree-issue-789-ghi/       # Agent 3's workspace
```

Each worktree has its own:

- Working directory with files
- Index (staging area)
- HEAD reference

But shares the same:

- Object database (.git/objects)
- Remote configuration
- Hooks

### Technical Environment

- Agents run in Docker containers
- Workspace volumes mounted from host
- Projects cloned once, worktrees created per agent run
- Git 2.40+ available in containers

## Research Findings

### Investigation Process

1. Analyzed git worktree mechanics and limitations
2. Reviewed aidp's worktree usage patterns
3. Evaluated storage and performance implications
4. Designed cleanup strategies for orphaned worktrees
5. Tested concurrent worktree operations

### Key Discoveries

**Git Worktree Commands:**

```bash
# Create worktree with new branch from origin/main
git worktree add -b feature-123 /path/to/worktree origin/main

# List all worktrees
git worktree list

# Remove worktree (requires workdir deletion first)
git worktree remove /path/to/worktree

# Prune stale worktrees (refs to deleted directories)
git worktree prune
```

**Worktree Limitations:**

1. **Branch uniqueness**: A branch can only be checked out in one worktree at a time
2. **Path must exist**: Worktree directory must not exist when creating
3. **Shared locks**: Some operations lock the main repository briefly
4. **Pruning required**: Deleting directories without `git worktree remove` leaves stale references

**Branch Naming Strategy:**

To avoid conflicts and enable tracking:

```
paid-agent-{issue_id}-{timestamp}-{short_hash}
```

Example: `paid-agent-123-20250123-a1b2c3`

**Storage Efficiency:**

Worktrees share the object database:

- Initial clone: ~100MB-1GB depending on repo
- Each worktree: ~50-200MB (working directory only)
- vs. full clone per agent: ~100MB-1GB each

For 10 parallel agents on a 500MB repo:

- With worktrees: 500MB + (10 × 100MB) = 1.5GB
- Without worktrees: 10 × 500MB = 5GB

**Cleanup Strategies:**

1. **Immediate cleanup**: Remove worktree after PR creation
   - Pro: Minimal storage
   - Con: Can't recover if something goes wrong

2. **Deferred cleanup**: Keep worktree for grace period
   - Pro: Allows debugging, recovery
   - Con: More storage usage

3. **Reference-based cleanup**: Keep until PR merged/closed
   - Pro: Full traceability
   - Con: Most storage usage

**Orphan Detection:**

Worktrees can become orphaned if:

- Container crashes during agent run
- Agent is interrupted without cleanup
- Worker process dies unexpectedly

Detection query:

```sql
SELECT w.path, w.branch_name, ar.status
FROM worktrees w
LEFT JOIN agent_runs ar ON ar.id = w.agent_run_id
WHERE w.status = 'active'
  AND (ar.status IN ('failed', 'cancelled', 'completed')
       OR ar.id IS NULL
       OR w.created_at < NOW() - INTERVAL '24 hours');
```

## Proposed Solution

### Approach

Use **git worktrees** with:

1. **Unique branch names**: Include issue ID, timestamp, and random suffix
2. **Per-project main clone**: Single clone, multiple worktrees
3. **Immediate cleanup**: Remove worktree after successful PR
4. **Orphan cleanup job**: Background job cleans stale worktrees
5. **Database tracking**: Record all worktrees for management

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        WORKTREE ARCHITECTURE                                 │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         HOST FILESYSTEM                                  ││
│  │                                                                          ││
│  │  /var/paid/workspaces/                                                  ││
│  │  ├── account-1/                                                         ││
│  │  │   ├── project-1/                                                     ││
│  │  │   │   ├── .git/                    # Shared git database             ││
│  │  │   │   ├── main/                    # Main branch (fetch target)      ││
│  │  │   │   ├── worktree-123-abc/        # Agent run 1                     ││
│  │  │   │   └── worktree-456-def/        # Agent run 2                     ││
│  │  │   └── project-2/                                                     ││
│  │  │       ├── .git/                                                      ││
│  │  │       └── main/                                                      ││
│  │  └── account-2/                                                         ││
│  │      └── ...                                                            ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    │ Volume mount                            │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         CONTAINER                                        ││
│  │                                                                          ││
│  │  /workspace/                                                             ││
│  │  ├── .git/ -> /workspaces/project-1/.git                               ││
│  │  └── worktree-123-abc/                                                  ││
│  │      ├── src/                                                           ││
│  │      ├── tests/                                                         ││
│  │      └── ...                                                            ││
│  │                                                                          ││
│  │  Agent works in: /workspace/worktree-123-abc/                           ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Storage efficiency**: Shared object database saves significant space
2. **Isolation**: Each agent has independent working directory
3. **Branch safety**: Git enforces one worktree per branch
4. **aidp-proven**: Pattern validated in production
5. **Native git**: No custom tooling required

### Implementation Example

```ruby
# app/services/worktree_service.rb
class WorktreeService
  include Servo::Service

  class Create
    include Servo::Service

    input do
      attribute :container_id, Dry::Types["strict.integer"]
      attribute :issue, Dry::Types["any"]
    end

    output do
      attribute :worktree_id, Dry::Types["strict.integer"]
      attribute :path, Dry::Types["strict.string"]
      attribute :branch_name, Dry::Types["strict.string"]
    end

    def call
      container = Container.find(container_id)
      project = container.project
      branch_name = generate_branch_name(issue)
      worktree_path = "/workspace/worktrees/#{branch_name}"

      # Fetch latest from remote
      execute_git(container, [
        "fetch", "origin", project.github_default_branch
      ])

      # Create worktree with new branch
      execute_git(container, [
        "worktree", "add",
        "-b", branch_name,
        worktree_path,
        "origin/#{project.github_default_branch}"
      ])

      # Record in database
      worktree = Worktree.create!(
        container_id: container_id,
        agent_run_id: Current.agent_run_id,
        project_id: project.id,
        path: worktree_path,
        branch_name: branch_name,
        base_commit: current_commit(container, "origin/#{project.github_default_branch}"),
        status: :active
      )

      success(
        worktree_id: worktree.id,
        path: worktree_path,
        branch_name: branch_name
      )
    rescue Git::GitExecuteError => e
      failure(error: "Failed to create worktree: #{e.message}")
    end

    private

    def generate_branch_name(issue)
      timestamp = Time.current.strftime("%Y%m%d%H%M%S")
      suffix = SecureRandom.hex(3)
      "paid-agent-#{issue.id}-#{timestamp}-#{suffix}"
    end

    def execute_git(container, args)
      container.exec(["git", "-C", "/workspace/repo", *args])
    end

    def current_commit(container, ref)
      result = container.exec(["git", "-C", "/workspace/repo", "rev-parse", ref])
      result.first.strip
    end
  end

  class Cleanup
    include Servo::Service

    input do
      attribute :worktree_id, Dry::Types["strict.integer"]
    end

    def call
      worktree = Worktree.find(worktree_id)
      container = worktree.container

      return success if worktree.cleaned?

      # Remove worktree
      execute_git(container, [
        "worktree", "remove", "--force", worktree.path
      ])

      # Delete branch if not pushed
      unless worktree.pushed?
        execute_git(container, [
          "branch", "-D", worktree.branch_name
        ])
      end

      worktree.update!(status: :cleaned, cleaned_at: Time.current)

      success
    rescue Git::GitExecuteError => e
      # Log but don't fail - orphan cleanup will catch it
      Rails.logger.warn("Worktree cleanup failed: #{e.message}")
      worktree.update!(status: :cleanup_failed)
      success
    end

    private

    def execute_git(container, args)
      container.exec(["git", "-C", "/workspace/repo", *args])
    end
  end
end

# app/jobs/orphan_worktree_cleanup_job.rb
class OrphanWorktreeCleanupJob < ApplicationJob
  queue_as :maintenance

  def perform
    # Find orphaned worktrees
    orphans = Worktree.where(status: :active)
      .where("created_at < ?", 24.hours.ago)
      .or(Worktree.joins(:agent_run).where(agent_runs: { status: [:completed, :failed, :cancelled] }))

    orphans.find_each do |worktree|
      begin
        cleanup_worktree(worktree)
      rescue => e
        Rails.logger.error("Orphan cleanup failed for worktree #{worktree.id}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    end

    # Prune git worktree references
    Project.active.find_each do |project|
      prune_worktree_refs(project)
    end
  end

  private

  def cleanup_worktree(worktree)
    project = worktree.project
    repo_path = workspace_path(project)

    # Remove from filesystem if exists
    worktree_full_path = File.join(repo_path, worktree.path.sub("/workspace/", ""))
    FileUtils.rm_rf(worktree_full_path) if File.exist?(worktree_full_path)

    # Clean up branch if not pushed
    unless worktree.pushed?
      system("git", "-C", repo_path, "branch", "-D", worktree.branch_name, exception: false)
    end

    # Prune worktree refs
    system("git", "-C", repo_path, "worktree", "prune")

    worktree.update!(status: :cleaned, cleaned_at: Time.current)
  end

  def prune_worktree_refs(project)
    repo_path = workspace_path(project)
    return unless File.exist?(repo_path)

    system("git", "-C", repo_path, "worktree", "prune")
  end

  def workspace_path(project)
    "/var/paid/workspaces/#{project.account_id}/#{project.id}"
  end
end
```

## Alternatives Considered

### Alternative 1: Full Clone Per Agent

**Description**: Clone the entire repository for each agent run

**Pros**:

- Complete isolation
- No worktree complexity
- Simpler mental model

**Cons**:

- Storage inefficient (full repo per agent)
- Slow (clone time for each run)
- Network bandwidth intensive

**Reason for rejection**: Too slow and storage-intensive for parallel agent execution. A 500MB repo with 10 parallel agents would require 5GB vs 1.5GB with worktrees.

### Alternative 2: Shallow Clones

**Description**: Use `git clone --depth 1` for each agent

**Pros**:

- Faster than full clones
- Less storage than full clones
- Simple isolation

**Cons**:

- Still slower than worktrees
- Can't reference older commits easily
- Still duplicates files across agents

**Reason for rejection**: Worktrees are still more efficient and faster once the initial clone exists.

### Alternative 3: Shared Checkout with File Locking

**Description**: Single checkout with file-level locking

**Pros**:

- Minimal storage
- Simplest approach

**Cons**:

- Agents would conflict on same files
- Locking complexity
- Serial execution only (defeats parallel agents)

**Reason for rejection**: Fundamentally incompatible with parallel agent execution.

### Alternative 4: Copy-on-Write Filesystems

**Description**: Use filesystem-level CoW (btrfs, zfs) for efficient clones

**Pros**:

- Instant copies
- Automatic deduplication
- No git worktree complexity

**Cons**:

- Requires specific filesystem
- Host dependency
- Not available in all environments
- Harder to reason about storage

**Reason for rejection**: Adds infrastructure requirements. Git worktrees work on any filesystem and are more portable.

## Trade-offs and Consequences

### Positive Consequences

- **Storage efficiency**: ~70% less storage than full clones
- **Fast creation**: Worktree creation is nearly instant
- **Full git functionality**: Complete history, branches, commits
- **Parallel safety**: Git enforces isolation
- **Simple cleanup**: Remove directory and prune

### Negative Consequences

- **Shared lock contention**: Brief locks during some operations
- **Orphan management**: Need background cleanup job
- **Complexity**: Team must understand worktree mechanics
- **Database tracking**: Additional state to manage

### Risks and Mitigations

- **Risk**: Worktree corruption from container crashes
  **Mitigation**: Background cleanup job runs regularly. Git worktree prune handles stale refs.

- **Risk**: Branch name collisions
  **Mitigation**: Include timestamp and random suffix in branch names. Statistically negligible collision risk.

- **Risk**: Storage grows unbounded with orphaned worktrees
  **Mitigation**: Aggressive cleanup (24-hour orphan detection). Storage monitoring alerts.

## Implementation Plan

### Prerequisites

- [ ] Docker volumes configured for workspaces
- [ ] Git 2.40+ in agent container image
- [ ] Database tables for worktree tracking

### Step-by-Step Implementation

#### Step 1: Create Workspace Directory Structure

```bash
mkdir -p /var/paid/workspaces
chown -R paid:paid /var/paid/workspaces
```

#### Step 2: Database Migration

```ruby
# db/migrate/xxx_create_worktrees.rb
class CreateWorktrees < ActiveRecord::Migration[8.0]
  def change
    create_table :worktrees do |t|
      t.references :container, foreign_key: true
      t.references :agent_run, foreign_key: true
      t.references :project, null: false, foreign_key: true

      t.string :path, null: false
      t.string :branch_name, null: false
      t.string :base_commit, limit: 40
      t.string :status, default: 'active'
      t.boolean :pushed, default: false

      t.timestamp :cleaned_at
      t.timestamps
    end

    add_index :worktrees, [:project_id, :branch_name], unique: true
    add_index :worktrees, :status
  end
end
```

#### Step 3: Initial Clone Service

```ruby
class ProjectCloneService
  include Servo::Service

  input do
    attribute :project_id, Dry::Types["strict.integer"]
  end

  def call
    project = Project.find(project_id)
    repo_path = workspace_path(project)

    if File.exist?(repo_path)
      # Fetch latest
      system("git", "-C", repo_path, "fetch", "--prune", "origin")
    else
      # Initial clone
      FileUtils.mkdir_p(File.dirname(repo_path))
      system(
        "git", "clone",
        "--bare",
        project.clone_url_with_token,
        "#{repo_path}/.git"
      )

      # Create main worktree
      system(
        "git", "-C", repo_path,
        "worktree", "add", "main", project.github_default_branch
      )
    end

    success
  end

  private

  def workspace_path(project)
    "/var/paid/workspaces/#{project.account_id}/#{project.id}"
  end
end
```

#### Step 4: Configure Cleanup Job

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.enable_cron = true
  config.good_job.cron = {
    orphan_cleanup: {
      cron: "0 * * * *",
      class: "OrphanWorktreeCleanupJob"
    }
  }
end
```

### Files to Modify

- `db/migrate/xxx_create_worktrees.rb` - Worktree tracking table
- `app/models/worktree.rb` - Worktree model
- `app/services/worktree_service.rb` - Create/cleanup services
- `app/services/project_clone_service.rb` - Initial clone management
- `app/jobs/orphan_worktree_cleanup_job.rb` - Orphan cleanup
- `config/initializers/good_job.rb` - Schedule cleanup job

### Dependencies

- Git 2.40+ (in container and optionally on host for cleanup)
- Docker volume mounts

## Validation

### Testing Approach

1. Unit tests for worktree service
2. Integration tests for parallel agent execution
3. Stress tests for concurrent worktree operations
4. Cleanup job tests with orphan scenarios

### Test Scenarios

1. **Scenario**: Create worktree for new agent run
   **Expected Result**: Worktree created, branch exists, database record created

2. **Scenario**: Two agents work on same project simultaneously
   **Expected Result**: Both have independent worktrees, no conflicts

3. **Scenario**: Agent container crashes mid-execution
   **Expected Result**: Orphan cleanup job removes stale worktree within 24 hours

4. **Scenario**: Cleanup worktree after successful PR
   **Expected Result**: Worktree removed, branch deleted, database marked cleaned

### Performance Validation

- Worktree creation < 5 seconds
- Cleanup < 2 seconds
- No git lock contention under 10 parallel agents

### Security Validation

- Worktrees isolated per account (directory structure)
- No cross-project access possible
- Branches use unpredictable names (include random suffix)

## References

### Requirements & Standards

- Paid AGENT_SYSTEM.md - Agent execution architecture
- [Git Worktree Documentation](https://git-scm.com/docs/git-worktree)

### Dependencies

- [Git](https://git-scm.com/)
- Docker volume mounts

### Research Resources

- aidp worktree implementation
- Git worktree internals
- Concurrent git operation safety

## Notes

- Consider implementing worktree pooling for faster agent startup
- Monitor disk usage trends to tune cleanup aggressiveness
- Branch name format may need adjustment if issues have very long IDs
- Future: Consider git protocol v2 for faster fetch operations
