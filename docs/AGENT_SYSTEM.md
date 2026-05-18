# Paid Agent System

This document describes how Paid executes AI agents, manages containers, and orchestrates workflows using Temporal.

## Overview

The agent system has four layers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          AGENT SYSTEM LAYERS                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ 1. WORKFLOW LAYER (Temporal)                                           │ │
│  │    Durable, observable orchestration of multi-step agent operations    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ 2. ACTIVITY LAYER (Temporal Workers)                                   │ │
│  │    Discrete units of work: clone, run agent, create PR, etc.           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ 3. CONTAINER LAYER (Docker)                                            │ │
│  │    Isolated execution environments with agent CLIs installed           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ 4. AGENT LAYER (agent-harness gem)                                       │ │
│  │    Unified interface to CLI agents (Claude Code, Cursor, Gemini CLI,   │ │
│  │    GitHub Copilot, Codex, Aider, OpenCode, Kilocode)                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Temporal Workflows

### Workflow Types

#### GitHubPollWorkflow

Continuously monitors a GitHub repository for actionable labels.

```ruby
# Pseudocode - actual implementation in Ruby with temporalio-ruby
class GitHubPollWorkflow
  def execute(project_id)
    loop do
      # Check for labeled issues
      issues = activity.fetch_labeled_issues(project_id)

      issues.each do |issue|
        case issue.trigger_label
        when :plan
          workflow.start_child(PlanningWorkflow, issue_id: issue.id)
        when :build
          workflow.start_child(AgentExecutionWorkflow, issue_id: issue.id)
        when :review
          workflow.start_child(ReviewWorkflow, pr_id: issue.pr_id)
        end
      end

      # Sleep until next poll (configurable per project)
      workflow.sleep(project.poll_interval)
    end
  end
end
```

**Characteristics:**

- Long-running (runs continuously while project is active)
- Cancellable via UI
- Handles rate limiting gracefully
- Logs all detected labels for audit

#### PlanningWorkflow

Decomposes a feature request into sub-issues.

```ruby
class PlanningWorkflow
  def execute(issue_id)
    issue = activity.fetch_issue(issue_id)
    project = issue.project

    # Select model for planning task
    model = activity.select_model(
      task_type: :planning,
      project_id: project.id,
      complexity: estimate_complexity(issue)
    )

    # Generate plan using API mode (no container needed)
    plan = activity.generate_plan(
      issue: issue,
      model: model,
      prompt_slug: "planning.feature_decomposition",
      style_guide: project.style_guide
    )

    # Create sub-issues in GitHub
    sub_issues = activity.create_sub_issues(
      project: project,
      parent_issue: issue,
      plan: plan
    )

    # Add to GitHub Project if available
    if project.projects_enabled?
      activity.add_to_github_project(sub_issues)
    end

    # Remove plan label, add appropriate next labels
    activity.update_issue_labels(
      issue: issue,
      remove: [:plan],
      add: [:planned]
    )

    { sub_issue_ids: sub_issues.map(&:id) }
  end
end
```

**Characteristics:**

- Relatively quick (minutes, not hours)
- Uses API mode for LLM calls
- Creates audit trail in GitHub

#### AgentExecutionWorkflow

Runs an agent to implement a specific issue.

```ruby
class AgentExecutionWorkflow
  def execute(issue_id, options = {})
    issue = activity.fetch_issue(issue_id)
    project = issue.project

    # Check budget before starting
    budget_ok = activity.check_budget(project.id)
    unless budget_ok
      activity.add_issue_comment(issue, "Budget limit reached. Pausing.")
      return { status: :budget_exceeded }
    end

    # Select model
    model = activity.select_model(
      task_type: :coding,
      project_id: project.id,
      issue: issue
    )

    # Select agent type (or use override)
    agent_type = options[:agent_type] || activity.select_agent_type(model)

    # Provision container and worktree
    container = activity.provision_container(project.id)
    worktree = activity.create_worktree(
      container: container,
      branch_name: generate_branch_name(issue)
    )

    begin
      # Run the agent with monitoring
      result = activity.run_agent(
        container: container,
        worktree: worktree,
        agent_type: agent_type,
        model: model,
        issue: issue,
        prompt_slug: "coding.implement_issue",
        style_guide: project.style_guide,
        # Guardrails
        max_iterations: 10,
        max_tokens: 100_000,
        timeout_minutes: 30
      )

      if result.success?
        # Create PR
        pr = activity.create_pull_request(
          project: project,
          worktree: worktree,
          issue: issue,
          result: result
        )

        activity.update_issue_labels(
          issue: issue,
          remove: [:build],
          add: [:in_review]
        )

        { status: :success, pr_url: pr.url }
      else
        activity.add_issue_comment(issue, "Agent failed: #{result.error}")
        activity.update_issue_labels(issue: issue, add: [:needs_input])

        { status: :failed, error: result.error }
      end

    ensure
      # Always clean up
      activity.cleanup_worktree(worktree)
      activity.release_container(container)
    end
  end
end
```

**Characteristics:**

- Medium duration (minutes to an hour)
- Heavy resource usage (container, API calls)
- Monitored for runaway behavior
- Always cleans up resources

#### PromptEvolutionWorkflow

Evolves prompts based on measured performance.

```ruby
class PromptEvolutionWorkflow
  def execute(prompt_id)
    prompt = activity.fetch_prompt(prompt_id)

    # Sample recent runs using this prompt
    samples = activity.sample_agent_runs(
      prompt_id: prompt_id,
      count: 20,
      min_age_hours: 24  # Let quality metrics settle
    )

    return { status: :insufficient_data } if samples.size < 10

    # Evaluate quality across samples
    analysis = activity.analyze_quality(samples)

    if analysis.quality_score >= 0.8
      # Prompt is performing well, no evolution needed
      return { status: :satisfactory, score: analysis.quality_score }
    end

    # Generate prompt mutations
    mutations = activity.generate_mutations(
      prompt: prompt,
      analysis: analysis,
      mutation_count: 3
    )

    # Create new prompt versions for A/B testing
    variants = mutations.map do |mutation|
      activity.create_prompt_version(
        prompt: prompt,
        template: mutation.template,
        change_notes: mutation.reasoning,
        created_by: :evolution
      )
    end

    # Set up A/B test
    ab_test = activity.create_ab_test(
      prompt: prompt,
      control: prompt.current_version,
      variants: variants
    )

    { status: :evolution_started, ab_test_id: ab_test.id }
  end
end
```

**Characteristics:**

- Runs periodically (daily or weekly)
- Uses API mode for analysis and mutation
- Creates audit trail of evolution decisions

#### ParallelAgentExecutionWorkflow

Runs multiple agents concurrently on independent sub-issues within a feature.

```ruby
class ParallelAgentExecutionWorkflow
  def execute(issue_ids, options = {})
    results = issue_ids.map do |issue_id|
      workflow.start_child(
        AgentExecutionWorkflow,
        issue_id: issue_id,
        options: options,
        task_queue: Paid.agent_task_queue
      )
    end

    # Wait for all child workflows to complete
    outcomes = results.map(&:result)

    {
      total: outcomes.size,
      succeeded: outcomes.count { |o| o[:status] == :success },
      failed: outcomes.count { |o| o[:status] == :failed }
    }
  end
end
```

**Characteristics:**

- Fan-out/fan-in pattern for independent issues
- Each child runs in its own container and worktree (no conflicts)
- Parent workflow tracks aggregate progress

#### KnowledgeEvolutionWorkflow

Evolves the project's knowledge base by ingesting new patterns from completed runs.

```ruby
class KnowledgeEvolutionWorkflow
  def execute(project_id)
    project = Project.find(project_id)

    # Sample recent completed runs
    samples = activity.sample_agent_runs(
      project_id: project_id,
      count: 50,
      min_age_hours: 24
    )

    return { status: :insufficient_data } if samples.size < 10

    # Analyze patterns across runs
    patterns = activity.analyze_run_patterns(samples, project.knowledge_base)

    # Update knowledge base with new patterns
    activity.update_knowledge_base(project.knowledge_base, patterns)

    { status: :evolved, patterns_found: patterns.size }
  end
end
```

**Characteristics:**

- Runs periodically (weekly or after N completed runs)
- Feeds insights back into future agent executions
- Maintains project-specific knowledge artifacts

### Workflow Coordination

When multiple agents work on related issues:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    MULTI-AGENT COORDINATION                                  │
│                                                                              │
│  FeatureWorkflow (parent)                                                   │
│  ├── PlanningWorkflow                                                       │
│  │   └── Creates sub-issues A, B, C                                        │
│  │                                                                          │
│  └── Parallel execution:                                                    │
│      ├── AgentExecutionWorkflow (issue A) ──► PR #1                        │
│      ├── AgentExecutionWorkflow (issue B) ──► PR #2                        │
│      └── AgentExecutionWorkflow (issue C) ──► PR #3                        │
│                                                                              │
│  Coordination rules:                                                        │
│  • Each agent works in separate worktree (no conflicts)                     │
│  • If issue B depends on A, wait for A's PR to merge                       │
│  • Parent workflow tracks overall progress                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Temporal Activities

Activities are the building blocks that workflows compose. Each activity is:

- Idempotent (safe to retry)
- Bounded in time (has timeout)
- Monitored (logs, metrics)

### Core Activities

| Activity | Description | Typical Duration |
|----------|-------------|------------------|
| `FetchIssuesActivity` | Get issues with specific labels from GitHub | 1-5 seconds |
| `CreateSubIssuesActivity` | Create multiple GitHub issues | 2-10 seconds |
| `CreatePullRequestActivity` | Create PR with changes | 2-5 seconds |
| `UpdatePlanningLabelsActivity` | Update labels during planning workflow | <1 second |

### Agent Activities

| Activity | Description | Typical Duration |
|----------|-------------|------------------|
| `ProvisionContainerActivity` | Start or reuse Docker container | 5-30 seconds |
| `CreateWorktreeActivity` | Create git worktree in container | 2-10 seconds |
| `RunAgentActivity` | Execute agent CLI or API call | 1-30 minutes |
| `CleanupWorktreeActivity` | Remove worktree after completion | 1-5 seconds |
| `ReleaseContainerActivity` | Mark container as available | <1 second |
| `CleanupContainerActivity` | Stop and remove container resources | 1-5 seconds |

### Intelligence Activities

| Activity | Description | Typical Duration |
|----------|-------------|------------------|
| `DecomposeFeatureActivity` | Decompose feature request into sub-issues | 10-60 seconds |
| `GenerateMutationsActivity` | Create prompt variants | 10-30 seconds |
| `CheckQualityGateActivity` | Evaluate quality metrics against thresholds | 1-10 seconds |
| `SampleRunsActivity` | Sample recent agent runs for analysis | 1-5 seconds |

> **Note**: Model selection is handled by the `Models::MetaAgentSelector` service (not an activity). Cost/budget tracking is handled by the `TokenUsageTracker` service (not an activity).

### Activity Implementation Pattern

```ruby
class RunAgentActivity < Paid::Activity
  def execute(params)
    agent_run = AgentRun.find(params[:agent_run_id])
    project = agent_run.project

    provider = AgentHarness.provider(params[:agent_type])

    response = Timeout.timeout(project.max_execution_seconds) do
      provider.send_message(
        prompt: resolve_prompt(params[:prompt_slug], params[:issue]),
        model: params[:model]
      )
    end

    record_token_usage(response.tokens)
    record_quality_metrics(response)

    response
  rescue Timeout::Error
    Guardrails::ViolationHandler.new.handle(
      violation_type: :time_limit,
      agent_run: agent_run,
      details: { max_seconds: project.max_execution_seconds }
    )
    AgentResult.new(success: false, error: "Time limit exceeded")
  end
end
```

---

## Container Management

### Container Image

Based on `ubuntu:24.04` with Ruby 3.4.8 compiled from source and Node.js 22.13.0 from binary:

```dockerfile
# Dockerfile.agent
FROM ubuntu:24.04

# Ruby 3.4.8 compiled from source; Node.js 22.13.0 from binary archive

# Agent CLIs installed via build args from agent-harness
ARG CLAUDE_CODE_VERSION
ARG CURSOR_VERSION
# ... additional agent CLI versions passed as build args

# Additional tools: ast-grep, scc, ruby-maat, git-credential-paid

# Non-root user for agent execution
RUN useradd -m -s /bin/bash agent
USER agent

WORKDIR /workspace
```

### Container Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CONTAINER LIFECYCLE                                   │
│                                                                              │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐  │
│  │  Pull   │───►│  Start  │───►│  Clone  │───►│  Work   │───►│ Cleanup │  │
│  │  Image  │    │Container│    │  Repo   │    │ (agent) │    │         │  │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘  │
│       │              │              │              │              │         │
│       ▼              ▼              ▼              ▼              ▼         │
│    Once per      Per project    Per project    Per worktree   Per worktree │
│    deployment    (reusable)     (cached)       (isolated)     (always)     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Phase 1**: Containers are ephemeral (started per activity, stopped after)

**Future**: Container pool with warm containers per project

### Container Provisioning

```ruby
# app/services/containers/provision.rb
class Containers::Provision
  def call(agent_run:)
    project = agent_run.project

    # Check for available container
    container = find_available_container(project.id)
    return container if container

    # Start new container
    container = docker_client.containers.create(
      image: "paid-agent:latest",
      name: "paid-#{project.id}-#{SecureRandom.hex(4)}",
      env: {
        "PROJECT_ID" => project.id.to_s
      },
      volumes: {
        workspace_path(project) => { "bind" => "/workspace", "mode" => "rw" }
      },
      network_mode: "paid-network",
      memory: "4g",
      cpu_quota: 200_000
    )

    container.start

    Container.create!(
      project_id: project.id,
      docker_id: container.id,
      status: :running
    )
  end
end
```

### Git Worktree Management

Worktree operations run on the **host filesystem**, not inside containers. Container-based git clone and worktree setup uses `Containers::GitOperations` instead.

```ruby
# Host-side worktree management
class WorktreeService
  def create(project:, branch_name:)
    repo_path = host_repo_path(project)
    worktree_path = "#{repo_path}/../worktrees/#{branch_name}"

    # Fetch latest from remote (on host)
    system("git -C #{repo_path} fetch origin")

    # Create worktree from latest main (on host)
    system([
      "git", "-C", repo_path, "worktree", "add",
      "-b", branch_name,
      worktree_path,
      "origin/#{project.github_default_branch}"
    ])

    Worktree.create!(
      project_id: project.id,
      path: worktree_path,
      branch_name: branch_name,
      status: :active
    )
  end

  def cleanup(worktree)
    repo_path = File.dirname(worktree.path)

    system(["git", "-C", repo_path, "worktree", "remove", "--force", worktree.path])
    system(["git", "-C", repo_path, "branch", "-D", worktree.branch_name])

    worktree.update!(status: :cleaned)
  end
end
```

For container-internal git operations (clone, commit, push), see `Containers::GitOperations`.

---

## The agent-harness Gem

Paid adopts the existing `agent-harness` gem for CLI agent orchestration and provider abstraction (see RDR-007).

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          agent-harness GEM                                     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         AgentHarness (public API)                         ││
│  └──────────────────────────────────┬──────────────────────────────────────┘│
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     Orchestration::Conductor                             ││
│  └──────────────────────────────────┬──────────────────────────────────────┘│
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         Providers::Registry                              ││
│  └──────────────────────────────────┬──────────────────────────────────────┘│
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │        Providers::Base (Claude, Cursor, Gemini, etc.)                    ││
│  └──────────────────────────────────┬──────────────────────────────────────┘│
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │               AgentHarness::Response + TokenTracker                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Provider Registry

Built-in providers include Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, and Kilocode. Providers expose capabilities (streaming, file_upload, vision, tool_use, json_mode, mcp, dangerous_mode), firewall requirements, and instruction file paths. The registry also supports aliases (e.g., `:anthropic` → `:claude`, `:copilot` → `:github_copilot`).

### Response Shape

`AgentHarness::Response` captures output, exit status, duration, provider, model, optional token usage (`tokens` hash), and error details, with `success?`/`failed?` helpers. Runtime failures are raised as typed exceptions (e.g., `RateLimitError`, `TimeoutError`, `NoProvidersAvailableError`).

### Usage

```ruby
AgentHarness.configure do |config|
  config.default_provider = :claude
  config.fallback_providers = [:cursor, :gemini]
end

response = AgentHarness.send_message("Implement the requested change", provider: :claude)
puts response.output if response.success?
```

```ruby
AgentHarness.token_tracker.on_tokens_used do |event|
  # event.provider, event.model, event.total_tokens
end
```

### API Mode (Outside agent-harness)

Paid uses `AgentHarness.send_message` directly for planning, quality evaluation, and other non-CLI tasks (e.g., PR description generation, issue analysis, prompt evolution).

---

## Service Containers

Agents frequently need external services (databases, caches, browsers) to run tests and setup commands. Service containers provide these as shared Docker containers on the same network as the agent.

### Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              Docker Network (paid_agent or paid_internal)                     │
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ Agent         │  │ PostgreSQL   │  │ Redis        │  │ Selenium     │    │
│  │ Container     │  │ Container    │  │ Container    │  │ Container    │    │
│  │               │  │              │  │              │  │              │    │
│  │ DATABASE_URL  │  │ :5432        │  │ :6379        │  │ :4444        │    │
│  │ REDIS_URL     │  │              │  │              │  │              │    │
│  │ SELENIUM_URL  │  │              │  │              │  │              │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Provisioning Flow

Service containers are provisioned as part of the agent execution workflow via `ProvisionServicesActivity`:

1. **Record association** — The agent run's `service_container_ids` is updated with the IDs of all service containers for the project. This happens before starting containers so that concurrent cleanup operations count this run.

2. **Ensure running** — For each service container (under a row-level lock):
   - If already running and Docker container is alive: reuse it
   - If marked running but Docker container is dead: re-provision
   - If stopped: pull image, create Docker container, start, wait for health check

3. **Generate env vars** — Well-known environment variables are generated based on the image type and stored in `agent_run.service_environment`:
   - `postgres` → `DATABASE_URL=postgres://agent:agent@<name>:5432/agent_test`
   - `redis` → `REDIS_URL=redis://<name>:6379`
   - `selenium`/`chromium` → `SELENIUM_URL=http://<name>:4444`
   - Other images → `SERVICE_<NAME>_HOST` and `SERVICE_<NAME>_PORT`

4. **Pass to agent** — The generated env vars are injected into the agent container's environment.

### Network Setup

Service containers are placed on the same Docker network as the agent container. The network is selected from the same per-run contract used by `Containers::Provision`:

- **`paid_agent`** — Restricted network for proxy-mode API-key auth. Outbound traffic is limited to the secrets proxy, GitHub, DNS, and service containers via iptables rules.
- **`paid_internal`** — Infrastructure network for subscription-auth mode (e.g., `claude login`) and direct-outbound provider runs. Allows outbound HTTPS for direct provider API access.

Service containers register a DNS alias matching their name, so agents can reach them by hostname (e.g., `proj-postgres`, `proj-redis`).

### Shared Containers and Reference Counting

Service containers are **shared across concurrent agent runs** within a project. This avoids the overhead of starting duplicate Postgres or Redis instances for each run.

**Cleanup safety** is ensured by reference counting:

- `ServiceContainer#active_agent_run_count` uses a PostgreSQL JSONB containment query to count active runs referencing the container.
- `ServiceProvisioner#cleanup(agent_run)` only stops containers with zero active runs.
- `DockerOrphanCleanupJob` (every 5 minutes) catches containers missed by normal cleanup.

### Image Allowlist

Operators control which Docker images can be used as service containers through the admin settings UI:

- **Storage**: `UserSetting#allowed_service_images` (JSONB array per admin/owner user)
- **Defaults**: `postgres:16`, `redis:7-alpine`, `selenium/standalone-chromium:latest`
- **Validation**: `ServiceContainer` validates the image against the union of allowlists from account admins/owners
- **Admin UI**: Managed via user settings as a comma-separated list (#245)

### Health Checking

The provisioner waits up to 30 seconds for a service container to become healthy using dual-mode checks:

1. **Docker HEALTHCHECK** — If the image defines one (or the provisioner configures one, as it does for Postgres with `pg_isready`), the Docker health status is monitored.
2. **TCP port probe** — If no Docker HEALTHCHECK is available, the provisioner probes the service port via TCP socket.

### Resource Limits

Each service container runs with bounded resources:

| Image Pattern | Memory | CPU | PIDs |
|---------------|--------|-----|------|
| `postgres`    | 2 GB   | 1   | 200  |
| `redis`       | 1 GB   | 1   | 100  |
| `selenium`    | 2 GB   | 2   | 300  |
| `chromium`    | 2 GB   | 2   | 300  |
| _(default)_   | 1 GB   | 1   | 200  |

### Background Operations

Three background jobs maintain service container health:

| Job | Schedule | Purpose |
|-----|----------|---------|
| `ServiceContainerMetricsCollectionJob` | Self-rescheduling while running | Collects CPU/memory/PID metrics |
| `ServiceContainerReconciliationJob` | Every 5 minutes | Corrects DB status when Docker state drifts |
| `DockerOrphanCleanupJob` | Every 5 minutes | Removes containers with zero active runs |

### Operator Configuration

Service containers are configured per-project through the admin UI:

1. **Add service containers** to a project (image, name, port, optional env overrides)
2. **Manage the image allowlist** in user settings (comma-separated list of allowed Docker images)
3. **Monitor** service container status in the admin dashboard (metrics and active run counts are planned for a future iteration, tracked in #245)
4. **Lifecycle operations** (stop, restart) via the admin UI are planned future work tracked in #246

For the full architectural decision record, see [RDR-020](rdrs/RDR-020-service-container-architecture.md).

---

## Agent Monitoring

### Guardrails

Every agent run is monitored for:

| Guardrail | Trigger | Action |
|-----------|---------|--------|
| Iteration limit | > N iterations | Stop agent, partial result |
| Token limit | > N tokens used | Stop agent, partial result |
| Time limit | > N minutes | Kill agent, partial result |
| Cost limit | > $N spent | Stop agent, alert user |
| Infinite loop | Same output 3x | Stop agent, flag for review |

### Implementation

Guardrails are enforced by separate, focused services:

- **`AgentRuns::DetectInfiniteLoop`** — detects repeated identical output patterns
- **`TokenUsageTracker`** — enforces cost/token limits per project and per run
- **`Guardrails::ViolationHandler`** — unified handler that processes violations and transitions agent runs to appropriate terminal states

`RunAgentActivity` checks `project.max_execution_seconds` for time limits and wraps agent execution in a timeout.

```ruby
# Guardrails::ViolationHandler handles these violation types:
# - :loop_detected   → AgentRuns::DetectInfiniteLoop
# - :token_limit     → TokenUsageTracker
# - :cost_limit      → TokenUsageTracker
# - :time_limit      → RunAgentActivity (project.max_execution_seconds)
# - :anomaly         → heuristic anomaly detection

module Guardrails
  class ViolationHandler
    VIOLATION_TYPES = %i[loop_detected token_limit cost_limit time_limit anomaly].freeze

    def handle(violation_type:, agent_run:, details: {})
      raise ArgumentError, "Unknown violation: #{violation_type}" unless VIOLATION_TYPES.include?(violation_type)

      agent_run.update!(
        status: :failed,
        failure_reason: violation_type,
        failure_details: details
      )

      Rails.logger.info(
        message: "guardrails.violation",
        agent_run_id: agent_run.id,
        violation_type: violation_type,
        details: details
      )
    end
  end
end
```

---

## Worker Configuration

### Task Queue Isolation

`bin/temporal_worker` supports `TEMPORAL_WORKER_MODE=poll`, `TEMPORAL_WORKER_MODE=agent`, or `TEMPORAL_WORKER_MODE=both`.
By default it runs **two Temporal workers** in a single process, each polling a
dedicated task queue. This isolates time-sensitive poll workflows from long-running
agent-execution workloads, preventing the noisy-neighbor problem where saturated agent
activity slots starve poll cycles.

In local development, `bin/dev` starts two dedicated worker processes from
`Procfile.dev`: `worker_poll` runs with `TEMPORAL_WORKER_MODE=poll`, and
`worker_agent` runs with `TEMPORAL_WORKER_MODE=agent`.

| Task queue | Default name | Workflows | Purpose |
|---|---|---|---|
| **Poll queue** | `paid-poll-tasks` | `GitHubPollWorkflow` | Short-lived poll activities with a small, fixed activity pool. Ensures `last_polled_at` freshness is independent of agent load. |
| **Agent queue** | `paid-agent-tasks` | `AgentExecutionWorkflow`, `PlanningWorkflow`, `ParallelAgentExecutionWorkflow` | Long-running agent activities with a larger pool. |

Both workers register **all activities** — the queue assignment determines which worker
picks up workflow tasks and their associated activity invocations.

Child workflows started from the poll workflow (e.g., `PlanningWorkflow`) are explicitly
routed to the agent task queue so they don't consume poll worker capacity.

#### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TEMPORAL_WORKER_MODE` | `both` | Run only the `poll` worker, only the `agent` worker, or both |
| `TEMPORAL_POLL_TASK_QUEUE` | `paid-poll-tasks` | Poll worker task queue name |
| `TEMPORAL_AGENT_TASK_QUEUE` | `paid-agent-tasks` | Agent worker task queue name |
| `TEMPORAL_POLL_ACTIVITY_SLOTS` | `10` | Max concurrent poll activities |
| `TEMPORAL_POLL_WORKFLOW_SLOTS` | `20` | Max concurrent poll workflow tasks |
| `TEMPORAL_ACTIVITY_SLOTS` | `4` | Max concurrent agent activities |
| `TEMPORAL_WORKFLOW_SLOTS` | `20` | Max concurrent agent workflow tasks |

### Worker Process

```ruby
# bin/temporal_worker (simplified)
poll_worker = Temporalio::Worker.new(
  client: Paid.temporal_client,
  task_queue: Paid.poll_task_queue,   # "paid-poll-tasks"
  activities: all_activities,
  workflows: [Workflows::GitHubPollWorkflow],
  tuner: Temporalio::Worker::Tuner.create_fixed(activity_slots: 10)
)

agent_worker = Temporalio::Worker.new(
  client: Paid.temporal_client,
  task_queue: Paid.agent_task_queue,  # "paid-agent-tasks"
  activities: all_activities,
  workflows: [Workflows::AgentExecutionWorkflow, ...],
  tuner: Temporalio::Worker::Tuner.create_fixed(activity_slots: 4)
)

workers =
  case ENV.fetch("TEMPORAL_WORKER_MODE", "both")
  when "poll" then [poll_worker]
  when "agent" then [agent_worker]
  when "both" then [poll_worker, agent_worker]
  else raise ArgumentError, "Invalid TEMPORAL_WORKER_MODE: #{ENV["TEMPORAL_WORKER_MODE"].inspect}"
  end

Temporalio::Worker.run_all(*workers, cancellation: shutdown)
```

### Docker Compose Integration

```yaml
# docker-compose.yml (excerpt)
services:
  temporal-worker:
    build:
      context: .
      dockerfile: Dockerfile
    command: bin/temporal_worker
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
      - RAILS_ENV=production
      - DATABASE_URL=postgres://...
    depends_on:
      - temporal
      - postgres
    deploy:
      replicas: 5  # Worker pool size
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock  # For container management
```

---

## Error Handling

### Retry Strategy

Activities use Temporal's built-in retry:

```ruby
class RunAgentActivity < Paid::Activity
  activity_options(
    start_to_close_timeout: 45.minutes,
    retry_policy: {
      initial_interval: 1.second,
      backoff_coefficient: 2.0,
      max_interval: 1.minute,
      max_attempts: 3,
      non_retryable_error_types: [
        "ApplicationError"  # non_retryable: true errors are never retried
      ]
    }
  )
end
```

### Failure Handling in Workflows

```ruby
class AgentExecutionWorkflow
  def execute(issue_id)
    begin
      # ... normal flow ...
    rescue ApplicationError => e
      if e.non_retryable
        activity.mark_agent_run_failed(agent_run, e)
      else
        raise  # let Temporal retry
      end
    end
  end
end
```

`MarkAgentRunFailedActivity` is the centralized activity for recording failures: it updates the agent run status, records failure details, and triggers any required notifications.

---

## Observability

### Metrics to Track

| Metric | Source | Use |
|--------|--------|-----|
| Workflow duration | Temporal | Performance |
| Activity duration | Temporal | Bottleneck identification |
| Container startup time | Docker | Optimization target |
| Provider errors (categorized) | agent-harness | Reliability |
| Token usage | agent-harness | Cost tracking |
| PR merge rate | GitHub | Success metric |
| Error rate by type | All | Reliability |

### Dashboard Integration

The live dashboard receives updates via Action Cable, triggered by agent run status change callbacks through `LiveDashboardBroadcastJob`:

```ruby
class LiveDashboardBroadcastJob < ApplicationJob
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)

    ActionCable.server.broadcast("agent_run_#{agent_run.id}", {
      agent_run_id: agent_run.id,
      status: agent_run.status,
      runner: agent_run.runner,
      duration_seconds: agent_run.duration_seconds,
      tokens_used: agent_run.total_tokens_used,
      current_output: agent_run.latest_output&.last(500),
      timestamp: Time.current.iso8601
    })
  end
end
```

`LiveDashboardBroadcastJob` is enqueued automatically when an agent run's status changes (via an `after_commit` callback on the `AgentRun` model).

### Temporal UI

The Temporal UI (port 8080) provides:

- Workflow execution history
- Activity timing breakdown
- Error details and stack traces
- Pending workflow list
- Search by workflow ID

This complements Paid's dashboard for debugging and operations.
