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
├── services/             # Business logic via Servo service objects
├── workflows/            # Temporal workflow definitions
├── activities/           # Temporal activity implementations
├── adapters/             # External service adapters (GitHub, LLM providers)
├── views/                # Phlex view components and templates
└── jobs/                 # Background jobs (when Temporal isn't appropriate)
```

### Sandi Metz's Rules

Use these as guidelines for maintainability:

1. **Classes should target ~100 lines** (use static analysis for enforcement)
2. **Methods should target ~5 lines**
3. **Methods should accept maximum 4 parameters** (use keyword arguments or parameter objects)
4. **Controllers should instantiate only one object**

These are guidelines, not absolute rules. Document legitimate exceptions with reasoning.

### Service Objects with Servo

Business logic lives in service objects using [Servo](https://github.com/martinstreicher/servo). Servo provides a clean DSL for inputs/outputs, built-in validation, type checking, and callback support.

**Why Servo over vanilla service objects:**
- Declarative input/output definitions with type safety
- Built-in ActiveModel validations
- Consistent result interface (`.success?`, `.failure?`, `.errors`)
- Before/after/around callbacks via ActiveSupport
- Optional background job support

```ruby
# app/services/agent_runs/create.rb
module AgentRuns
  class Create < Servo::Base
    # Declare inputs with types
    input :project, type: Project
    input :issue, type: Issue
    input :agent_type, type: Types::String.optional

    # Declare outputs
    output :agent_run, type: AgentRun

    # Validations run before call
    validates :project, presence: true
    validates :issue, presence: true

    def call
      context.agent_run = AgentRun.create!(
        project: context.project,
        issue: context.issue,
        agent_type: context.agent_type || select_agent_type,
        status: :pending
      )
    end

    private

    def select_agent_type
      # Selection logic delegated to meta-agent
      ModelSelector.new.select_agent(context.issue)
    end
  end
end

# Usage
result = AgentRuns::Create.call(project: project, issue: issue)

if result.success?
  result.agent_run  # Access output
else
  result.errors     # ActiveModel::Errors
  result.error_messages  # Array of strings
end
```

**Controller Integration:**

```ruby
class AgentRunsController < ApplicationController
  include Servo::RailsConcern

  def create
    render_servo AgentRuns::Create.call(
      project: current_account.projects.find(params[:project_id]),
      issue: Issue.find(params[:issue_id])
    )
  end
end
```

**Organizing Services:**

```ruby
# Namespace by domain
AgentRuns::Create
AgentRuns::Cancel
AgentRuns::Retry

Projects::Import
Projects::Sync
Projects::Archive

Prompts::Evolve
Prompts::CreateABTest
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
- Prefer `timestamp` over `datetime`
- Prefer explicit columns over JSON blobs for queryable data

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

Logging is critical for debugging agent workflows and creating readable execution traces. Use structured logging with consistent component names and metadata.

### Log Levels

Each level serves a distinct purpose:

**`debug`** — Method calls, internal state changes, detailed execution flow
- Use for tracing code paths during development
- Log method entries with key parameters
- Log internal variable states when debugging complex logic
- These logs help answer "what code path did we take?"

**`info`** — Significant events, operation completions, user-initiated actions
- Workflow started/completed
- Agent run status changes
- User actions (project created, agent triggered)
- These logs tell the story of what happened at a business level

**`warn`** — Recoverable errors, degraded functionality, retry attempts
- API rate limits hit (with retry)
- Fallback to secondary provider
- Deprecated feature usage
- These indicate potential problems that didn't stop execution

**`error`** — Failures, exceptions, issues requiring attention
- Unrecoverable failures
- External service errors
- Validation failures that shouldn't happen
- These demand investigation

### When to Log

Log at these critical junctures to create readable execution traces:

- **Method entries**: Log entering important methods with key parameters (debug level)
- **State transitions**: Log mode/state/workflow changes (info level)
- **External interactions**: Log API calls, HTTP requests, provider interactions (info level)
- **File operations**: Log reads, writes, deletes with filenames (debug level)
- **Decision points**: Log branching logic explaining path selection (debug level)
- **Loop iterations**: Log progress with counts/identifiers, not every iteration (debug level)
- **Completions**: Log when multi-step operations finish with metrics (info level)

### Logging Pattern

```ruby
class AgentExecutionService
  COMPONENT = "agent_execution"

  def execute(agent_run)
    Rails.logger.info(
      message: "#{COMPONENT}.started",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      agent_type: agent_run.agent_type
    )

    Rails.logger.debug(
      message: "#{COMPONENT}.selecting_model",
      agent_run_id: agent_run.id,
      task_complexity: estimate_complexity(agent_run)
    )

    model = select_model(agent_run)

    Rails.logger.debug(
      message: "#{COMPONENT}.model_selected",
      agent_run_id: agent_run.id,
      model: model.id,
      reasoning: model.selection_reasoning
    )

    result = run_agent(agent_run, model)

    Rails.logger.info(
      message: "#{COMPONENT}.completed",
      agent_run_id: agent_run.id,
      iterations: result.iterations,
      tokens_used: result.token_usage.total,
      duration_ms: result.duration_ms,
      success: result.success?
    )

    result
  rescue => e
    Rails.logger.error(
      message: "#{COMPONENT}.failed",
      agent_run_id: agent_run.id,
      error_class: e.class.name,
      error_message: e.message
    )
    raise
  end
end
```

### Metadata Guidelines

**Include as metadata:**
- Identifiers (agent_run_id, project_id, workflow_id)
- Counts and sizes (iteration_count, token_count, file_count)
- Status codes and result types
- Timing information (elapsed_ms, duration_seconds)
- Filenames and paths (if not sensitive)

**Don't log:**
- Secrets, tokens, passwords, API keys (redaction is a safety net, not primary defense)
- Full request/response payloads (log summaries or sizes instead)
- Inside tight loops without throttling
- Redundant information already in the message

### Message Style

- **Use consistent component names**: `agent_execution`, `github_sync`, `prompt_evolution`, `container_manager`
- **Use dot notation**: `component.action` (e.g., `agent_execution.started`)
- **Present tense verbs**: "starting", "processing", "completing"
- **Put dynamic data in metadata hash**, not interpolated in message

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

Keep controllers thin — delegate to Servo services and use `render_servo`:

```ruby
class ProjectsController < ApplicationController
  include Servo::RailsConcern

  def create
    render_servo Projects::Create.call(
      account: current_account,
      user: current_user,
      params: project_params
    )
  end

  def show
    @project = current_account.projects.find(params[:id])
    authorize @project
  end
end
```

### Views with Phlex

Use [Phlex](https://www.phlex.fun/) for view components instead of ERB or ViewComponent. Phlex provides:
- Pure Ruby views (no template language)
- Better performance than ERB
- Easy composition and inheritance
- Type safety with Ruby

```ruby
# app/views/components/agent_run_status.rb
class Components::AgentRunStatus < Phlex::HTML
  def initialize(agent_run:)
    @agent_run = agent_run
  end

  def view_template
    div(class: "agent-run-status", data: { status: @agent_run.status }) do
      status_badge
      metrics if @agent_run.completed?
    end
  end

  private

  def status_badge
    span(class: "badge badge-#{status_color}") { @agent_run.status.humanize }
  end

  def status_color
    case @agent_run.status.to_sym
    when :completed then "success"
    when :failed then "danger"
    when :running then "warning"
    else "secondary"
    end
  end

  def metrics
    dl(class: "metrics") do
      dt { "Iterations" }
      dd { @agent_run.iterations.to_s }

      dt { "Tokens" }
      dd { number_with_delimiter(@agent_run.tokens_input + @agent_run.tokens_output) }

      dt { "Duration" }
      dd { distance_of_time_in_words(@agent_run.duration_seconds) }
    end
  end
end

# Usage in controller
def show
  render Components::AgentRunStatus.new(agent_run: @agent_run)
end
```

**Page Layout with Phlex:**

```ruby
# app/views/layouts/application_layout.rb
class Layouts::ApplicationLayout < Phlex::HTML
  include Phlex::Rails::Helpers::CSRFMetaTags
  include Phlex::Rails::Helpers::ContentFor

  def view_template(&block)
    doctype
    html do
      head do
        title { "Paid" }
        csrf_meta_tags
        stylesheet_link_tag "application"
        javascript_include_tag "application"
      end
      body do
        render Components::Navbar.new(user: Current.user)
        main(class: "container", &block)
        render Components::Footer.new
      end
    end
  end
end
```

### Hotwire/Turbo Integration

- Use Turbo Frames for partial page updates
- Use Turbo Streams for real-time updates (agent activity)
- Keep Stimulus controllers focused and small
- Phlex components work seamlessly with Turbo

```ruby
# Broadcasting agent activity updates
class AgentRun < ApplicationRecord
  after_update_commit :broadcast_status

  private

  def broadcast_status
    Turbo::StreamsChannel.broadcast_replace_to(
      "agent_run_#{id}",
      target: "agent_run_#{id}_status",
      html: Components::AgentRunStatus.new(agent_run: self).call
    )
  end
end
```

### Background Processing

**Prefer Temporal workflows** for any work that:
- May take more than a few seconds
- Needs retry logic or error handling
- Involves multiple steps or external services
- Benefits from observability and durability

**Use GoodJob** (PostgreSQL-backed) only for simple, fire-and-forget tasks that don't fit Temporal:
- Sending emails
- Cache warming
- Simple cleanup tasks
- Metric aggregation

```ruby
# PREFER: Temporal workflow for complex operations
class GitHubSyncWorkflow
  def execute(project_id)
    project = activity.fetch_project(project_id)
    issues = activity.fetch_issues(project)
    activity.sync_issues(project, issues)
    activity.update_project_status(project)
  end
end

# OK: GoodJob for simple tasks
class SendNotificationJob < ApplicationJob
  queue_as :default

  def perform(user_id, message)
    user = User.find(user_id)
    UserMailer.notification(user, message).deliver_now
  end
end
```

**GoodJob Configuration:**

```ruby
# config/application.rb
config.active_job.queue_adapter = :good_job

# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :async
  config.good_job.max_threads = 5
  config.good_job.poll_interval = 30
  config.good_job.shutdown_timeout = 25
end
```

**Why GoodJob over Sidekiq/Solid Queue:**
- Uses PostgreSQL (no Redis dependency)
- Transactional job enqueuing (jobs commit with your data)
- Built-in dashboard
- Cron-like scheduling

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

