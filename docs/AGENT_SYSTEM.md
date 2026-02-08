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
| `FetchIssueActivity` | Get single issue details | <1 second |
| `CreateSubIssuesActivity` | Create multiple GitHub issues | 2-10 seconds |
| `UpdateIssueLabelActivity` | Add/remove labels on issue | <1 second |
| `AddIssueCommentActivity` | Post comment to issue | <1 second |
| `CreatePullRequestActivity` | Create PR with changes | 2-5 seconds |

### Agent Activities

| Activity | Description | Typical Duration |
|----------|-------------|------------------|
| `ProvisionContainerActivity` | Start or reuse Docker container | 5-30 seconds |
| `CreateWorktreeActivity` | Create git worktree in container | 2-10 seconds |
| `RunAgentActivity` | Execute agent CLI or API call | 1-30 minutes |
| `CleanupWorktreeActivity` | Remove worktree after completion | 1-5 seconds |
| `ReleaseContainerActivity` | Mark container as available | <1 second |

### Intelligence Activities

| Activity | Description | Typical Duration |
|----------|-------------|------------------|
| `SelectModelActivity` | Choose model via meta-agent | 1-5 seconds |
| `GeneratePlanActivity` | Create implementation plan | 10-60 seconds |
| `EvaluateQualityActivity` | Calculate quality metrics | 1-10 seconds |
| `GenerateMutationsActivity` | Create prompt variants | 10-30 seconds |
| `CheckBudgetActivity` | Verify cost limits not exceeded | <1 second |

### Activity Implementation Pattern

```ruby
class RunAgentActivity < Paid::Activity
  def execute(params)
    container = params[:container]
    agent_type = params[:agent_type]
    prompt = resolve_prompt(params[:prompt_slug], params[:issue])

    # Set up monitoring
    monitor = AgentMonitor.new(
      max_iterations: params[:max_iterations],
      max_tokens: params[:max_tokens],
      timeout: params[:timeout_minutes].minutes
    )

    # Get the provider
    provider = AgentHarness.provider(agent_type)

    # Run with monitoring
    response = monitor.run do
      provider.send_message(
        prompt: prompt,
        model: params[:model]
      )
    end

    # Record metrics
    record_token_usage(response.tokens)
    record_quality_metrics(response)

    result
  rescue AgentMonitor::LimitExceeded => e
    # Graceful handling of guardrails
    AgentResult.new(success: false, error: e.message, partial_output: e.partial_output)
  end
end
```

---

## Container Management

### Container Image

Based on aidp's devcontainer, customized for Paid:

```dockerfile
# Dockerfile.agent
FROM ruby:3.4-bookworm

# System dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    build-essential \
    libpq-dev \
    nodejs \
    npm \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Install agent CLIs
RUN npm install -g @anthropic/claude-code \
    && npm install -g cursor-cli \
    && pip install openai-codex-cli \
    && gh extension install github/gh-copilot

# Firewall setup script
COPY scripts/setup-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/setup-firewall.sh

# Non-root user for agent execution
RUN useradd -m -s /bin/bash agent
USER agent

WORKDIR /workspace

# No secrets in image - they come via proxy
ENV PAID_PROXY_URL=http://host.docker.internal:3001
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
class ContainerService
  def provision(project_id)
    project = Project.find(project_id)

    # Check for available container
    container = find_available_container(project_id)
    return container if container

    # Start new container
    container = docker_client.containers.create(
      image: "paid-agent:latest",
      name: "paid-#{project_id}-#{SecureRandom.hex(4)}",
      env: {
        "PAID_PROXY_URL" => paid_proxy_url,
        "PROJECT_ID" => project_id.to_s
      },
      volumes: {
        workspace_path(project) => { "bind" => "/workspace", "mode" => "rw" }
      },
      network_mode: "paid-network",
      # Resource limits
      memory: "4g",
      cpu_quota: 200_000  # 2 CPUs
    )

    container.start

    # Clone repo if not already present
    ensure_repo_cloned(container, project)

    # Apply firewall rules
    apply_firewall(container)

    Container.create!(
      project_id: project_id,
      docker_id: container.id,
      status: :running
    )
  end

  private

  def apply_firewall(container)
    # Allowlist only necessary domains
    allowlist = [
      "api.anthropic.com",
      "api.openai.com",
      "generativelanguage.googleapis.com",
      "api.github.com",
      "github.com",
      # Paid proxy (for API key injection)
      "host.docker.internal"
    ]

    container.exec(["/usr/local/bin/setup-firewall.sh", *allowlist])
  end
end
```

### Git Worktree Management

Each agent works in an isolated worktree:

```ruby
class WorktreeService
  def create(container:, branch_name:)
    project = container.project
    repo_path = "/workspace/repo"
    worktree_path = "/workspace/worktrees/#{branch_name}"

    # Fetch latest from remote
    container.exec(["git", "-C", repo_path, "fetch", "origin"])

    # Create worktree from latest main
    container.exec([
      "git", "-C", repo_path, "worktree", "add",
      "-b", branch_name,
      worktree_path,
      "origin/#{project.github_default_branch}"
    ])

    Worktree.create!(
      container_id: container.id,
      path: worktree_path,
      branch_name: branch_name,
      status: :active
    )
  end

  def cleanup(worktree)
    container = worktree.container

    # Remove worktree
    container.exec([
      "git", "-C", "/workspace/repo", "worktree", "remove",
      "--force", worktree.path
    ])

    # Delete branch
    container.exec([
      "git", "-C", "/workspace/repo", "branch", "-D",
      worktree.branch_name
    ])

    worktree.update!(status: :cleaned)
  end
end
```

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

Paid uses ruby-llm directly for planning, quality evaluation, and other non-CLI tasks.

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

```ruby
class AgentMonitor
  class LimitExceeded < StandardError
    attr_reader :partial_output
    def initialize(message, partial_output = nil)
      super(message)
      @partial_output = partial_output
    end
  end

  def initialize(max_iterations:, max_tokens:, timeout:, cost_limit_cents: nil)
    @max_iterations = max_iterations
    @max_tokens = max_tokens
    @timeout = timeout
    @cost_limit_cents = cost_limit_cents
    @checkpoint = Checkpoint.new
  end

  def run(&block)
    Timeout.timeout(@timeout) do
      block.call(@checkpoint)
    end
  rescue Timeout::Error
    raise LimitExceeded.new("Timeout exceeded", @checkpoint.partial_output)
  end

  class Checkpoint
    attr_reader :partial_output

    def initialize
      @iterations = 0
      @tokens = 0
      @recent_outputs = []
      @partial_output = ""
    end

    def record_iteration(output)
      @iterations += 1
      @partial_output = output

      # Check for infinite loop (same output repeated)
      @recent_outputs << output.hash
      @recent_outputs = @recent_outputs.last(5)
      if @recent_outputs.uniq.size == 1 && @recent_outputs.size >= 3
        raise LimitExceeded.new("Infinite loop detected", output)
      end

      if @iterations > @max_iterations
        raise LimitExceeded.new("Iteration limit exceeded", output)
      end
    end

    def record_usage(usage)
      @tokens += usage.total
      if @tokens > @max_tokens
        raise LimitExceeded.new("Token limit exceeded", @partial_output)
      end
    end
  end
end
```

---

## Worker Configuration

### Fixed Pool (Phase 1)

```yaml
# config/temporal.yml
development:
  workers: 2
  task_queue: "paid-development"

production:
  workers: 5
  task_queue: "paid-production"
```

### Worker Process

```ruby
# bin/temporal-worker
require_relative "../config/environment"

worker = Temporal::Worker.new(
  client: Paid::TemporalClient.instance,
  task_queue: Rails.configuration.temporal[:task_queue]
)

# Register workflows
worker.register_workflow(GitHubPollWorkflow)
worker.register_workflow(PlanningWorkflow)
worker.register_workflow(AgentExecutionWorkflow)
worker.register_workflow(PromptEvolutionWorkflow)

# Register activities
worker.register_activity(FetchIssuesActivity)
worker.register_activity(RunAgentActivity)
worker.register_activity(CreatePullRequestActivity)
# ... etc

puts "Starting Temporal worker..."
worker.run
```

### Docker Compose Integration

```yaml
# docker-compose.yml (excerpt)
services:
  temporal-worker:
    build:
      context: .
      dockerfile: Dockerfile
    command: bin/temporal-worker
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
        AgentMonitor::LimitExceeded,  # Don't retry guardrail violations
        BudgetExceeded,               # Don't retry budget issues
        GitConflict                   # Needs human intervention
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
    rescue AgentMonitor::LimitExceeded => e
      handle_limit_exceeded(e)
    rescue BudgetExceeded => e
      handle_budget_exceeded(e)
    rescue => e
      handle_unexpected_error(e)
    end
  end

  private

  def handle_limit_exceeded(error)
    activity.add_issue_comment(
      @issue,
      "Agent stopped: #{error.message}\n\nPartial progress saved."
    )
    activity.update_issue_labels(@issue, add: [:needs_input])
    { status: :limit_exceeded, partial_output: error.partial_output }
  end

  def handle_budget_exceeded(error)
    activity.add_issue_comment(
      @issue,
      "Budget limit reached for this project. Please increase budget or wait for reset."
    )
    { status: :budget_exceeded }
  end
end
```

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

The live dashboard receives updates via Action Cable:

```ruby
class AgentRunBroadcaster
  def initialize(agent_run)
    @agent_run = agent_run
    @channel = "agent_run_#{agent_run.id}"
  end

  def broadcast_update(data)
    ActionCable.server.broadcast(@channel, {
      agent_run_id: @agent_run.id,
      status: @agent_run.status,
      provider: data[:provider],
      duration_seconds: data[:duration_seconds],
      tokens_used: data[:tokens_used],
      current_output: data[:output]&.last(500),  # Last 500 chars
      timestamp: Time.current.iso8601
    })
  end
end
```

### Temporal UI

The Temporal UI (port 8080) provides:

- Workflow execution history
- Activity timing breakdown
- Error details and stack traces
- Pending workflow list
- Search by workflow ID

This complements Paid's dashboard for debugging and operations.
