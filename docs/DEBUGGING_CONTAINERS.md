# Debugging Container Isolation

Guide for investigating issues with agent container isolation, git worktrees, and the agent execution pipeline.

## Architecture Overview

Agent runs execute inside isolated Docker containers. The execution flow is:

1. **ProvisionContainerActivity** — Creates a Docker container with an empty workspace directory
2. **CloneRepoActivity** — Clones the repo and creates a branch *inside* the container
3. **RunAgentActivity** — Executes the agent CLI *inside* the container via `docker exec`
4. **PushBranchActivity** — Pushes the branch from *inside* the container
5. **CleanupContainerActivity** — Removes the container and workspace directory

All git operations and agent execution happen inside the container. No git credentials or agent CLI processes should run on the host.

## Key Tables and Models

| Model | Key Fields | Purpose |
|-------|-----------|---------|
| `AgentRun` | `container_id`, `branch_name`, `base_commit_sha`, `worktree_path`, `temporal_workflow_id` | Tracks the full lifecycle |
| `Worktree` | `path`, `branch_name`, `base_commit`, `pushed`, `status` | Tracks git workspace state |
| `AgentRunLog` | `log_type`, `content`, `metadata` | Timestamped execution logs |

## Investigation Queries

### Inspect an agent run

```ruby
ar = AgentRun.find(ID)
ar.attributes
ar.agent_run_logs.order(:created_at).each { |l| puts "[#{l.created_at}] #{l.log_type}: #{l.content[0..200]}" }
```

### Check container state

```ruby
# Was a container provisioned?
ar.container_id  # nil means cleaned up or never created

# Was a worktree record created?
ar.worktree      # associated Worktree record
ar.worktree&.pushed?  # was the branch pushed to remote?
```

### Check for isolation failures

```ruby
# These should all be present for a successful isolated run:
ar.container_id.present?       # Container was provisioned
ar.base_commit_sha.present?    # Base commit was recorded inside container
ar.branch_name.present?        # Branch was created inside container
ar.temporal_workflow_id.present?  # Run went through Temporal (not a manual/legacy path)
ar.worktree_path == "/workspace"  # Container-side path (not a host path)
```

### Find runs that may have had isolation issues

```ruby
# Runs with missing container evidence
AgentRun.where(container_id: [nil, ""])
  .where.not(status: "pending")
  .pluck(:id, :status, :branch_name, :worktree_path)

# Runs with host-side worktree paths (should be "/workspace" for containerized runs)
AgentRun.where.not(worktree_path: [nil, "", "/workspace"])
  .pluck(:id, :worktree_path)

# Runs without Temporal workflow IDs (may have used a legacy execution path)
AgentRun.where(temporal_workflow_id: [nil, ""])
  .where.not(status: "pending")
  .pluck(:id, :status, :created_at)
```

## Log Analysis

Agent run logs are stored in the `agent_run_logs` table. Key log entries to look for:

### Container Lifecycle

| Log Content | Meaning |
|------------|---------|
| `container.provision.start` | Container creation began |
| `container.provision.success` | Container created (check `metadata.container_id`) |
| `container.provision.failed` | Container creation failed |
| `container.network.ready` | Network configured (check `metadata.network`) |
| `container.firewall.applied` | Firewall rules applied |
| `container.firewall.failed` | Firewall rules failed (check `metadata.error`) |
| `container.cleanup.start` | Container teardown began |
| `container.cleanup.success` | Container removed |

### Git Operations (inside container)

| Log Content | Meaning |
|------------|---------|
| `container.execute.start` with `git clone` | Repo clone inside container |
| `container.execute.start` with `git checkout -b` | Branch creation inside container |
| `container.execute.start` with `git push` | Branch push inside container |
| `container.execute.start` with `git diff` | Change detection inside container |

### Agent Execution

| Log Content | Meaning |
|------------|---------|
| `Starting <agent_type> agent in container` | Agent CLI started inside container |
| `Completed without PR: no_changes` | No changes detected after agent ran |

### Red Flags

- **`git clone` completing in < 1 second**: May indicate the workspace was pre-populated or the clone hit a cached/local path instead of the remote
- **`container.firewall.failed`**: Firewall not applied — the container may have unrestricted network access
- **Missing `container.provision.success` log**: Container was never created
- **`worktree_path` is a host path** (not `/workspace`): Agent may have run on the host filesystem
- **`base_commit_sha` is empty**: Base commit wasn't recorded, so change detection may fail

## Common Issues

### Agent commits to wrong branch

**Symptoms**: Commits appear on the host's checked-out branch instead of the agent's work branch.

**Cause**: The agent CLI was executed on the host (via `AgentHarness.send_message()`) instead of inside the container (via `container.exec()`). The agent sees the host repo and commits to whatever branch is checked out there.

**Verification**:

```bash
# Check which branches contain the suspect commit
git branch --contains <commit-sha>

# If the commit is only on the host's working branch (not a work/* or paid/* branch),
# the agent ran on the host instead of in the container.
```

**Fix**: Ensure `RunAgentActivity` uses `container_service.execute()` to run the agent CLI inside the container, not `AgentHarness.send_message()` on the host.

### Change detection reports "no changes" after agent committed

**Symptoms**: Agent output shows it committed changes, but the system reports `no_changes` and doesn't push or create a PR.

**Cause**: The `has_changes?` check compares against `base_commit_sha`. If `base_commit_sha` is empty, it falls back to `git diff --stat HEAD` which only detects *uncommitted* changes (not committed ones).

**Verification**:

```ruby
ar = AgentRun.find(ID)
ar.base_commit_sha  # Should be a 40-char SHA, not empty
```

### Docker-outside-of-Docker path mismatch

**Symptoms**: Container workspace is empty despite `git clone` showing success, or workspace contains unexpected content.

**Cause**: With Docker-outside-of-Docker (DooD), bind mount paths reference the **Docker host** filesystem, not the devcontainer filesystem. A path like `/var/paid/workspaces/runs/5/` created inside the devcontainer doesn't exist on the Docker host.

**Verification**:

```bash
# Check if WORKSPACE_ROOT exists on the Docker host
docker run --rm -v /var/paid/workspaces:/check alpine ls /check

# Check what the agent container actually sees
docker exec <container_id> ls -la /workspace
```

**Mitigation**: Use Docker volumes instead of bind mounts, or ensure workspace paths map correctly between the devcontainer and Docker host.

### Container firewall not applied

**Symptoms**: `container.firewall.failed` in logs with `iptables: not found`.

**Cause**: The agent container image doesn't have `iptables` installed.

**Verification**:

```bash
docker run --rm paid-agent:latest which iptables
```

**Impact**: Without firewall rules, the container's network restrictions depend solely on the Docker network configuration (`internal: true`). The container may be able to reach more endpoints than intended.

## Docker Inspection Commands

```bash
# List running agent containers
docker ps --filter "label=paid.agent_run_id"

# Inspect a specific container
docker inspect <container_id> | jq '.[0].HostConfig.Binds'
docker inspect <container_id> | jq '.[0].NetworkSettings.Networks'

# Check container resource limits
docker inspect <container_id> | jq '.[0].HostConfig.Memory, .[0].HostConfig.CpuQuota'

# Execute a command inside a running container
docker exec <container_id> git -C /workspace log --oneline -5
docker exec <container_id> git -C /workspace branch

# Check what network the container is on
docker network inspect paid_agent
docker network inspect paid_internal
```

## Temporal Workflow Inspection

```bash
# List recent workflows (requires temporal CLI or UI at localhost:8080)
tctl workflow list --query "WorkflowType='AgentExecutionWorkflow'"

# Get workflow details
tctl workflow show --workflow_id <workflow_id>

# Check workflow history (useful for seeing which activities ran and their results)
tctl workflow showid <workflow_id> --print_raw_time
```

Or use the Temporal UI at `http://localhost:8080` to browse workflow executions, activity results, and error details.

## Git Verification

```bash
# Check which branches contain a specific commit
git branch -a --contains <sha>

# Verify a commit is only on work branches (not main or feature branches)
git log --all --oneline --source | grep <sha>

# Check if any work branches exist for a given agent run
git branch -a | grep "paid/paid-agent-<run_id>"

# Verify the remote has the expected branch
git ls-remote origin | grep "paid/"
```
