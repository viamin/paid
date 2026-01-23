# Paid Style Guide

This style guide establishes coding standards, architectural patterns, and best practices for developing Paid (Platform for AI Development). It is adapted from [aidp's style guide](https://github.com/viamin/aidp/blob/main/docs/STYLE_GUIDE.md) with modifications for a Rails web application context.

---

## Core Architectural Principles

### Code Organization

Organize code by capability rather than workflow. Favor small, focused classes that do one thing well.

**Guidelines:**
- Break large classes into specialized components
- Group utilities by their purpose to maximize reusability
- Prefer composition over inheritance
- Keep models focused on data and validation; extract business logic to service objects

**Rails-Specific Organization:**
```
app/
├── controllers/          # Thin controllers, one object per action
├── models/               # ActiveRecord models, validations, scopes
├── services/             # Business logic (verb-named: CreateProject, RunAgent)
├── jobs/                 # Background jobs (Solid Queue)
├── workflows/            # Temporal workflow definitions
├── activities/           # Temporal activity implementations
├── adapters/             # External service adapters (GitHub, LLM providers)
├── presenters/           # View logic extraction
└── components/           # ViewComponents for reusable UI
```

### Sandi Metz's Rules

Use these as guidelines for maintainability:

1. **Classes should target ~100 lines** (use static analysis for enforcement)
2. **Methods should target ~5 lines**
3. **Methods should accept maximum 4 parameters** (use keyword arguments or parameter objects)
4. **Controllers should instantiate only one object**

These are guidelines, not absolute rules. Document legitimate exceptions with reasoning.

### Service Object Pattern

Business logic lives in service objects, not models or controllers:

```ruby
# app/services/agent_runs/create.rb
module AgentRuns
  class Create
    def initialize(project:, issue:, agent_type: nil)
      @project = project
      @issue = issue
      @agent_type = agent_type
    end

    def call
      # Business logic here
      AgentRun.create!(
        project: @project,
        issue: @issue,
        agent_type: @agent_type || select_agent_type,
        status: :pending
      )
    end

    private

    def select_agent_type
      # Selection logic
    end
  end
end

# Usage
AgentRuns::Create.new(project: project, issue: issue).call
```

---

## Ruby & Rails Standards

### Convention Compliance

- Follow [StandardRB](https://github.com/standardrb/standard) style guidelines
- Use `frozen_string_literal: true` at the top of all Ruby files
- Use `require_relative` over `require` for local files
- Use meaningful naming (avoid `get_`/`set_` prefixes)
- No commented-out code
- No TODO comments without issue references: `# TODO(#123): description`

### Rails Conventions

- Use strong parameters in controllers
- Prefer scopes over class methods for queries
- Use `find_each` for batch processing large datasets
- Use database constraints in addition to model validations
- Prefer `where.not` over raw SQL for negation

### Naming Conventions

```ruby
# Services: verb + noun
CreateProject, RunAgent, SyncGitHubIssues

# Jobs: noun + verb + "Job"
AgentRunCleanupJob, PromptEvolutionJob

# Workflows: noun + "Workflow"
AgentExecutionWorkflow, GitHubPollWorkflow

# Activities: verb + noun + "Activity"
RunAgentActivity, CreatePullRequestActivity
```

### Database Conventions

- Use UUIDs for external-facing IDs, bigints for internal references
- Always add foreign key constraints
- Index foreign keys and frequently queried columns
- Use `jsonb` for flexible schema fields (with appropriate indexes)
- Prefer `timestamp` over `datetime`

---

## AI Integration Patterns

### Zero Framework Cognition (ZFC)

Delegate semantic reasoning to AI models while keeping orchestration code "dumb" and mechanical.

> **Principle:** If it requires understanding meaning, ask the AI. If it's purely mechanical, keep it in code.

**ZFC-Compliant (keep in code):**
- Pure orchestration and I/O
- Structural safety checks
- Policy enforcement (budgets, rate limits)
- Mechanical transforms (parsing, formatting)
- State management

**ZFC Violations (delegate to AI):**
- Reasoning about code quality
- Plan composition and decomposition
- Semantic analysis of issues or PRs
- Quality judgments
- Pattern matching for meaning

```ruby
# GOOD: Mechanical orchestration, semantic work delegated
class PlanningService
  def create_plan(issue)
    # Mechanical: fetch context
    context = build_context(issue)

    # Semantic: delegated to AI
    plan = llm_client.generate_plan(context)

    # Mechanical: store result
    save_plan(plan)
  end
end

# BAD: Semantic logic in code
class PlanningService
  def create_plan(issue)
    # Don't do this - semantic analysis in code
    if issue.title.include?("bug")
      plan_type = :bugfix
    elsif issue.body.length > 500
      plan_type = :complex_feature
    end
  end
end
```

### AI-Generated Determinism (AGD)

Use AI once during configuration to generate deterministic artifacts that run without AI at runtime.

**Examples:**
- Style guide compression: AI analyzes codebase once, generates compressed guide
- Model selection rules: AI creates selection criteria, rules execute without AI
- Quality thresholds: AI determines appropriate thresholds, code enforces them

This complements ZFC by front-loading AI work for high-frequency operations.

---

## Structured Logging

Logging is critical for debugging agent workflows. Use Rails logger with consistent structure.

### Log Levels

- **Debug**: Method calls, internal state changes, detailed flow
- **Info**: Significant events, workflow completions, user actions
- **Warn**: Recoverable errors, retries, degraded operation
- **Error**: Failures requiring attention, unrecoverable errors

### Logging Pattern

```ruby
class AgentExecutionService
  def execute(agent_run)
    Rails.logger.info(
      "agent_execution.started",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      agent_type: agent_run.agent_type
    )

    result = run_agent(agent_run)

    Rails.logger.info(
      "agent_execution.completed",
      agent_run_id: agent_run.id,
      iterations: result.iterations,
      tokens_used: result.token_usage.total,
      duration_ms: result.duration_ms
    )

    result
  rescue => e
    Rails.logger.error(
      "agent_execution.failed",
      agent_run_id: agent_run.id,
      error_class: e.class.name,
      error_message: e.message
    )
    raise
  end
end
```

### What to Log

- Method entries (with key parameters)
- State transitions
- External interactions (API calls, container operations)
- File and git operations
- Decision points
- Loop iteration progress (for long operations)
- Operation completions with metrics

### What NOT to Log

- Secrets (API keys, tokens) — use redaction as safety net, not primary defense
- Full request/response payloads (log summary instead)
- Redundant information already in context
- High-frequency operations without aggregation

---

## Testing Architecture

### Test Organization

```
spec/
├── models/               # Model specs (validations, scopes, associations)
├── services/             # Service object specs
├── jobs/                 # Background job specs
├── workflows/            # Temporal workflow specs
├── activities/           # Temporal activity specs
├── adapters/             # External adapter specs (heavily mocked)
├── requests/             # Request specs for API endpoints
├── system/               # System specs for UI flows
└── support/              # Shared helpers and configurations
```

**Guidelines:**
- One spec file per class (path mirrors class path)
- Use `let` for setup, descriptive `context` blocks for scenarios
- Consolidate all examples for a class into its primary spec file
- No duplicate specs across multiple files

### Mocking Strategy

Mock only external dependencies:

```ruby
# GOOD: Mock external API
allow(Octokit::Client).to receive(:new).and_return(mock_github_client)

# GOOD: Mock LLM provider
allow(RubyLLM).to receive(:chat).and_return(mock_response)

# BAD: Don't mock application code
allow(AgentRuns::Create).to receive(:call)  # Don't do this

# GOOD: Use dependency injection instead
service = AgentRuns::Create.new(
  project: project,
  github_client: mock_github_client  # Inject mock
)
```

### Coverage Philosophy

Target 85-100% coverage for business logic with pragmatic exceptions:

- **External boundaries**: Test the interface, not provider internals
- **Container operations**: Mock Docker interactions, test orchestration logic
- **Temporal workflows**: Use Temporal's testing framework

### Pending Specs Policy

Maintain strict discipline:

- Previously passing specs **must NOT** become pending
- Fix regressions or deliberately delete specs with justification
- Only use `pending` for clearly identified future work
- Every pending spec must include reasoning plus issue reference

```ruby
# GOOD
pending "supports parallel agent execution (#45)"

# BAD
pending "fix later"
```

---

## Error Handling

### Strategy

- **Let it crash** for internal state corruption — fail fast, fix root cause
- **Handle gracefully** exceptions from external dependencies (GitHub, LLM APIs)
- Use **specific error types**, not generic rescue
- Always preserve context for debugging

```ruby
class GitHubService
  class RateLimitExceeded < StandardError; end
  class TokenInvalid < StandardError; end

  def fetch_issues(project)
    client.issues(project.github_full_name)
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("github.rate_limited", project_id: project.id, retry_after: e.retry_after)
    raise RateLimitExceeded, "Rate limited, retry after #{e.retry_after}s"
  rescue Octokit::Unauthorized => e
    Rails.logger.error("github.unauthorized", project_id: project.id)
    raise TokenInvalid, "GitHub token invalid or expired"
  end
end
```

### Temporal Error Handling

Use Temporal's retry policies for transient failures:

```ruby
class RunAgentActivity < Paid::Activity
  activity_options(
    retry_policy: {
      initial_interval: 1.second,
      backoff_coefficient: 2.0,
      maximum_interval: 1.minute,
      maximum_attempts: 3,
      non_retryable_errors: [
        BudgetExceeded,      # Don't retry business rule violations
        TokenInvalid,        # Don't retry auth failures
        GuardrailTriggered   # Don't retry limit violations
      ]
    }
  )
end
```

---

## Quality & Performance

### Performance Guidelines

- Avoid O(n²) complexity over large datasets
- Batch database operations (`insert_all`, `update_all`)
- Use `find_each` for processing large record sets
- Stream large files instead of loading into memory
- Cache expensive operations (model lookups, API responses)

```ruby
# GOOD: Batch insert
TokenUsage.insert_all(usage_records)

# GOOD: Streaming large output
File.open(log_path, 'a') do |f|
  agent_output.each_line { |line| f.puts(line) }
end

# BAD: Load everything into memory
all_logs = AgentRunLog.where(agent_run: run).pluck(:content).join
```

### Security & Safety

- Never execute untrusted code outside containers
- Validate file paths (prevent directory traversal)
- Sanitize inputs to shell commands
- Use parameterized queries (ActiveRecord does this by default)
- Redact secrets in logs (safety net, not primary defense)

---

## Development Workflow

### Commit Hygiene

- One logical change per commit
- Descriptive messages explaining **why**, not just what
- Reference issue IDs for non-trivial changes

```
# GOOD
Add budget limit enforcement to agent execution (#42)

Agents now check project budget before starting and abort if
the daily limit would be exceeded. This prevents surprise costs
when agents run many iterations.

# BAD
fix stuff
```

### Backward Compatibility Policy

For pre-release (v0.x.x), we explicitly **reject backward compatibility**:

- Remove old implementations immediately
- Update all callers in the same commit
- No "legacy" methods, aliases, or compatibility flags
- Prefer a single, clear implementation path

This keeps the codebase clean and avoids maintenance burden during rapid iteration.

### Code Review Focus

Reviews should examine:

- Adherence to Sandi Metz's rules (with documented exceptions)
- Test coverage and clarity
- Specific error handling (no bare `rescue`)
- ZFC compliance (semantic logic delegated to AI)
- StandardRB compliance
- Security considerations for container/secrets handling

---

## Rails-Specific Patterns

### Controllers

Keep controllers thin — one object per action:

```ruby
class ProjectsController < ApplicationController
  def create
    @project = Projects::Create.new(
      user: current_user,
      params: project_params
    ).call

    respond_to do |format|
      format.html { redirect_to @project }
      format.turbo_stream
    end
  end
end
```

### Hotwire/Turbo Patterns

- Use Turbo Frames for partial page updates
- Use Turbo Streams for real-time updates (agent activity)
- Keep Stimulus controllers focused and small
- Prefer server-side rendering over client-side JavaScript

```ruby
# Broadcasting agent activity updates
class AgentRun < ApplicationRecord
  after_update_commit -> {
    broadcast_replace_to(
      "agent_run_#{id}",
      partial: "agent_runs/status",
      locals: { agent_run: self }
    )
  }
end
```

### Background Jobs

Use Solid Queue for background processing:

```ruby
class GitHubSyncJob < ApplicationJob
  queue_as :default

  retry_on Octokit::TooManyRequests, wait: :polynomially_longer, attempts: 5
  discard_on Octokit::Unauthorized  # Don't retry auth failures

  def perform(project_id)
    project = Project.find(project_id)
    GitHubSyncService.new(project).sync
  end
end
```

### Database Transactions

Use transactions for multi-step operations:

```ruby
class AgentRuns::Complete
  def call(agent_run, result)
    ActiveRecord::Base.transaction do
      agent_run.update!(
        status: :completed,
        completed_at: Time.current
      )

      QualityMetric.create!(
        agent_run: agent_run,
        iterations_to_complete: result.iterations,
        # ...
      )

      TokenUsage.create!(
        agent_run: agent_run,
        tokens_input: result.token_usage.input,
        tokens_output: result.token_usage.output
      )
    end
  end
end
```

---

## Knowledge Management

### Project-Specific Documentation

Add architectural decisions and patterns to this style guide rather than external systems. This provides:

- Zero context overhead for AI agents
- Git versioning and history
- Automatic integration into development workflow
- No additional dependencies

When adding new patterns or conventions, update this document with:
- The pattern name and description
- When to use it (and when not to)
- A code example
- Rationale for the decision

### Persistent Task Tracking

Use GitHub Issues for cross-session work tracking:

- Create issues for discovered sub-tasks during implementation
- Reference issues in commits and code comments
- Use labels to categorize (bug, enhancement, tech-debt)
- Link related issues for context

---

## Summary

This style guide emphasizes:

1. **Small, focused components** following Sandi Metz's rules
2. **Service objects** for business logic, thin controllers
3. **ZFC compliance** — delegate semantic reasoning to AI
4. **Structured logging** for debuggability
5. **Strict testing discipline** with pragmatic coverage targets
6. **Explicit error handling** with specific error types
7. **No backward compatibility** during pre-release development
8. **Rails conventions** with Hotwire for real-time UI

The goal is a maintainable, testable codebase that leverages AI appropriately while keeping orchestration logic simple and mechanical.
