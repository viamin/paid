# Paid Style Guide

This style guide establishes coding standards, architectural patterns, and best practices for developing Paid (Platform for AI Development). It is adapted from [aidp's style guide](https://github.com/viamin/aidp/blob/main/docs/STYLE_GUIDE.md) with modifications for a Rails web application context.

The guide emphasizes detailed reasoning for each decision. Understanding *why* a pattern exists is as important as knowing the pattern itself—it enables developers to make good judgment calls in novel situations.

---

## Core Architectural Principles

### Zero Framework Cognition (ZFC)

Zero Framework Cognition is the principle that orchestration code should remain mechanically simple, delegating all semantic reasoning to AI models. The core insight: **if understanding meaning is required, ask the AI; if it's purely mechanical, keep it in code.**

**Rationale**: Hard-coded heuristics become maintenance burdens. They encode assumptions that break as contexts change. Regex patterns for semantic meaning, scoring formulas based on keyword counts, and branching logic based on content analysis all suffer from the same problem: they bake in human judgment that becomes stale.

**ZFC-Compliant Operations** (keep in code):

- Pure orchestration and I/O (reading files, calling APIs, saving results)
- Structural safety checks (file exists? valid JSON? under size limit?)
- Policy enforcement (budget limits, rate limiting, authorization)
- Mechanical transforms (parsing known formats, string manipulation)
- State management (workflow status, progress tracking)

**ZFC Violations** (delegate to AI):

- Reasoning about code quality or correctness
- Plan composition and task decomposition
- Semantic analysis of issues, PRs, or code
- Quality judgments and scoring
- Pattern matching for meaning (e.g., "is this a bug fix?")

```ruby
# ZFC-COMPLIANT: Mechanical orchestration
class PlanningService < Servo::Base
  input :issue, type: Issue
  output :plan, type: Plan

  def call
    # Mechanical: fetch data
    context_data = build_context(context.issue)

    # Semantic: delegated to AI (we don't try to decompose the issue ourselves)
    response = llm_client.generate(
      prompt: Prompts::FeatureDecomposition.render(context_data),
      schema: PlanSchema
    )

    # Mechanical: store result
    context.plan = Plan.create!(
      issue: context.issue,
      tasks: response.tasks
    )
  end
end

# ZFC VIOLATION: Semantic analysis in code
class PlanningService < Servo::Base
  def call
    # DON'T DO THIS - we're guessing at meaning based on surface patterns
    if context.issue.title.downcase.include?("bug")
      plan_type = :bugfix
      estimated_complexity = :low
    elsif context.issue.body.length > 1000
      plan_type = :large_feature
      estimated_complexity = :high
    elsif context.issue.labels.include?("urgent")
      plan_type = :hotfix
      estimated_complexity = :medium
    end
    # This logic WILL break. Issue titles lie. Length doesn't indicate complexity.
    # Labels are inconsistent. Let the AI assess based on actual content.
  end
end
```

The key test: if you're writing conditional logic that depends on understanding what text *means*, you're violating ZFC. Move that decision to an AI call with a structured schema for the response.

### AI-Generated Determinism (AGD)

AI-Generated Determinism complements ZFC by using AI once during configuration to generate deterministic artifacts that run without AI at runtime. This is appropriate when input formats are stable and decisions don't require fresh context.

**Rationale**: Some operations happen frequently enough that calling an AI model each time is expensive or slow, but the decision logic is complex enough that hand-coding it would violate ZFC. AGD front-loads the AI work.

**Examples in Paid**:

- **Style guide compression**: AI analyzes a codebase once and generates a compressed style guide that agents use in prompts. The analysis happens once; the compressed output is used repeatedly.
- **Model selection rules**: AI generates rules like "use claude-3-haiku for simple edits, claude-3-opus for architectural changes." The rules execute without AI calls.
- **Quality thresholds**: AI determines "for this project, 3+ iterations indicates a problem." Code enforces the threshold mechanically.

**When to use AGD vs ZFC**:

- AGD: Input format is stable, decisions can be pre-computed, cost/latency matters
- ZFC: Each input is unique, fresh context needed, accuracy matters more than speed

### Code Organization by Capability

Organize code by what it does (capability) rather than which workflow uses it. This maximizes reusability and prevents duplication.

**Anti-pattern**:

```
app/services/
├── github_sync/
│   ├── issue_parser.rb      # Parses issues for sync workflow
│   └── pr_analyzer.rb       # Analyzes PRs for sync workflow
├── agent_execution/
│   ├── issue_parser.rb      # Parses issues for agent workflow (duplicate!)
│   └── result_formatter.rb
```

**Preferred**:

```
app/services/
├── parsers/
│   └── issue_parser.rb      # One parser, used by any workflow that needs it
├── analyzers/
│   └── pr_analyzer.rb       # One analyzer
├── formatters/
│   └── result_formatter.rb  # One formatter
├── github_sync/
│   └── orchestrator.rb      # Composes parsers, analyzers as needed
├── agent_execution/
│   └── orchestrator.rb      # Composes different combinations
```

**Rationale**: When issue parsing logic changes (say, GitHub updates their API), you fix one file. When a new workflow needs issue parsing, it uses the existing parser. Duplication across workflows means bugs get fixed inconsistently and improvements don't propagate.

**Rails-Specific Organization**:

```
app/
├── controllers/          # Thin controllers delegating to services
├── models/               # ActiveRecord models: associations, validations, scopes
├── services/             # Business logic via Servo (organized by capability)
├── workflows/            # Temporal workflow definitions
├── activities/           # Temporal activity implementations
├── adapters/             # External service adapters (GitHub, LLM providers)
├── views/                # Phlex view components and templates
└── jobs/                 # GoodJob jobs (when Temporal isn't appropriate)
```

---

## Size and Complexity Guidelines

### Sandi Metz's Rules

These rules, from Sandi Metz's "Practical Object-Oriented Design," provide concrete targets for maintainable code:

1. **Classes should target ~100 lines**
2. **Methods should target ~5 lines**
3. **Methods should accept maximum 4 parameters**
4. **Controllers should instantiate only one object**

**Rationale**: Smaller units are easier to test, understand, and modify. A 100-line class can be read in one sitting. A 5-line method has one responsibility. Fewer parameters mean simpler interfaces and fewer ways to call something incorrectly.

These are guidelines, not laws. A data structure class might legitimately have 150 lines of attribute definitions. A complex algorithm might need a 20-line method. The point is to notice when you're exceeding these targets and consciously decide whether the exception is justified.

**Enforcement**: Use static analysis (RuboCop with appropriate cops) to flag violations during CI. Require justification comments for exceptions:

```ruby
# Exceeds 5-line method guideline: Complex state machine transition logic
# that's clearer as a single method than split across helpers.
def transition_to(new_state)
  # ... 12 lines of intentional complexity
end
```

### When to Extract

Extract when:

- A method does more than one thing (and, then, also)
- You're passing the same group of parameters to multiple methods (parameter object)
- A class has multiple reasons to change (violates single responsibility)
- You find yourself writing comments explaining what a section does (name it instead)

Don't extract when:

- The extraction would just move complexity, not reduce it
- The "extracted" code would only ever be called from one place
- The extraction requires passing many parameters, creating coupling

---

## Service Objects with Servo

Business logic lives in service objects using [Servo](https://github.com/martinstreicher/servo), not in models or controllers. Servo provides structure that vanilla service objects lack.

### Why Servo Over Vanilla Service Objects

Vanilla service objects vary wildly in implementation. Some use `call`, others `execute` or `perform`. Some return the result, others the service instance. Error handling is inconsistent. This creates cognitive load: every service requires reading to understand its interface.

Servo provides:

- **Declarative inputs/outputs with type checking**: Catches misuse early, documents expectations
- **Built-in ActiveModel validations**: Consistent validation that runs before `call`
- **Consistent result interface**: Always `.success?`, `.failure?`, `.errors`
- **Callbacks**: before/after/around hooks via ActiveSupport
- **Controller integration**: `render_servo` helper reduces boilerplate

```ruby
# app/services/agent_runs/create.rb
module AgentRuns
  class Create < Servo::Base
    # Inputs are documented and type-checked
    input :project, type: Project
    input :issue, type: Issue
    input :agent_type, type: Types::String.optional

    # Outputs are documented and type-checked
    output :agent_run, type: AgentRun

    # Validations run before call, failing early with clear errors
    validates :project, presence: true
    validates :issue, presence: true
    validate :project_has_budget

    # Before callbacks for setup
    before do
      Rails.logger.info(
        message: "agent_runs.create.starting",
        project_id: context.project.id,
        issue_id: context.issue.id
      )
    end

    def call
      context.agent_run = AgentRun.create!(
        project: context.project,
        issue: context.issue,
        agent_type: context.agent_type || select_agent_type,
        status: :pending
      )
    end

    private

    def project_has_budget
      return if context.project.budget_remaining?
      errors.add(:project, "has exceeded its budget")
    end

    def select_agent_type
      # Delegate to AI (ZFC-compliant)
      ModelSelection::SelectAgent.call(issue: context.issue).agent_type
    end
  end
end
```

### Usage Patterns

```ruby
# In controllers with Servo concern
class AgentRunsController < ApplicationController
  include Servo::RailsConcern

  def create
    render_servo AgentRuns::Create.call(
      project: current_account.projects.find(params[:project_id]),
      issue: Issue.find(params[:issue_id])
    )
  end
end

# In other services (composition)
class Features::Implement < Servo::Base
  input :feature_request, type: FeatureRequest

  def call
    # Decompose the feature
    plan_result = Planning::Decompose.call(feature_request: context.feature_request)
    fail_with(plan_result.errors) if plan_result.failure?

    # Create agent runs for each task
    plan_result.tasks.each do |task|
      run_result = AgentRuns::Create.call(
        project: context.feature_request.project,
        issue: task.issue,
        agent_type: task.recommended_agent
      )
      fail_with(run_result.errors) if run_result.failure?
    end
  end
end

# In tests
RSpec.describe AgentRuns::Create do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  it "creates an agent run" do
    result = described_class.call(project: project, issue: issue)

    expect(result).to be_success
    expect(result.agent_run).to be_persisted
    expect(result.agent_run.status).to eq("pending")
  end

  context "when project has no budget" do
    before { project.update!(budget_remaining_cents: 0) }

    it "fails with a clear error" do
      result = described_class.call(project: project, issue: issue)

      expect(result).to be_failure
      expect(result.errors[:project]).to include("has exceeded its budget")
    end
  end
end
```

### Organizing Services

Namespace by domain, verb-noun naming:

```ruby
# Agent execution domain
AgentRuns::Create
AgentRuns::Cancel
AgentRuns::Retry
AgentRuns::RecordResult

# Project management domain
Projects::Import
Projects::Sync
Projects::Archive
Projects::UpdateSettings

# Prompt system domain
Prompts::Evolve
Prompts::CreateVersion
Prompts::StartABTest
Prompts::PromoteWinner

# GitHub integration domain
GitHub::SyncIssues
GitHub::CreatePullRequest
GitHub::ParseWebhook
```

---

## Ruby and Rails Standards

### Convention Compliance

Follow [StandardRB](https://github.com/standardrb/standard) for formatting. StandardRB is "Ruby's bikeshed-proof linter and formatter"—it makes decisions so you don't have to argue about them.

Additional conventions:

- `frozen_string_literal: true` at the top of all Ruby files
- `require_relative` over `require` for local files (explicit dependencies)
- Meaningful names without noise words (`create_project` not `do_create_project_action`)
- No `get_`/`set_` prefixes (Ruby convention: `project` not `get_project`)
- No commented-out code (that's what git is for)
- No TODO without issue reference: `# TODO(#123): description`

**Rationale for no orphan TODOs**: TODOs without tracking disappear. They accumulate, become stale, and developers learn to ignore them. Requiring an issue reference ensures the work is tracked and prioritized appropriately.

### Database Conventions

- **UUIDs for external-facing IDs, bigints for internal references**: External IDs (in URLs, APIs) should be UUIDs to prevent enumeration attacks and sequential guessing. Internal foreign keys can be bigints for efficiency.

- **Always add foreign key constraints**: Rails doesn't add these by default, but they prevent orphaned records and catch bugs early. Use `foreign_key: true` in migrations.

- **Index foreign keys and frequently queried columns**: Every `belongs_to` column needs an index. Columns in `WHERE`, `ORDER BY`, or `JOIN` clauses need indexes.

- **Prefer `timestamp` over `datetime`**: PostgreSQL's `timestamp` type is more precise and uses less storage.

- **Prefer explicit columns over JSON blobs for queryable data**: JSON columns are convenient but harder to query, index, and validate. Use them for truly schemaless data (user preferences, external API responses), not for structured data you'll query.

### Naming Conventions

```ruby
# Services: VerbNoun (what it does)
CreateProject
SyncGitHubIssues
EvolvePrompt

# Jobs: NounVerbJob (what + when)
AgentRunCleanupJob
PromptEvolutionJob
MetricAggregationJob

# Workflows: NounWorkflow (the domain entity)
AgentExecutionWorkflow
GitHubPollWorkflow
FeatureImplementationWorkflow

# Activities: VerbNounActivity (the action)
RunAgentActivity
CreatePullRequestActivity
FetchIssuesActivity

# Adapters: ServiceNameAdapter (the external service)
GitHubAdapter
AnthropicAdapter
OpenAIAdapter
```

---

## Structured Logging

Logging is critical for debugging agent workflows and creating readable execution traces. Poor logging makes production issues nearly impossible to diagnose; good logging makes them obvious.

### Philosophy

Logs serve multiple audiences:

- **Developers debugging**: Need detailed flow, variable states, decision points
- **Operators monitoring**: Need significant events, errors, performance metrics
- **Auditors reviewing**: Need who did what when, security-relevant events

Structure logs for machine parsing (JSON) while keeping them human-readable. Include correlation IDs to trace requests across services.

### Log Levels in Detail

**`debug`** — Method calls, internal state changes, detailed execution flow

Debug logs answer "what code path did we take?" They're verbose by design and typically disabled in production unless actively debugging.

Use debug for:

- Method entry with key parameters
- Internal variable states when debugging complex logic
- Loop iteration details (but throttle—don't log every iteration)
- Conditional branch decisions ("taking path A because X")

```ruby
Rails.logger.debug(
  message: "agent_execution.selecting_model",
  agent_run_id: agent_run.id,
  issue_complexity: complexity_score,
  budget_remaining_cents: project.budget_remaining_cents,
  candidate_models: candidates.map(&:id)
)
```

**`info`** — Significant events, operation completions, user-initiated actions

Info logs tell the story of what happened at a business level. They should be readable as a narrative: "User created project. Agent run started. Agent run completed successfully."

Use info for:

- Workflow and operation start/completion
- User actions (project created, agent triggered, settings changed)
- Significant state changes (agent run status transitions)
- Integration events (webhook received, PR created)

```ruby
Rails.logger.info(
  message: "agent_execution.completed",
  agent_run_id: agent_run.id,
  project_id: project.id,
  iterations: result.iterations,
  tokens_used: result.token_usage.total,
  duration_ms: elapsed_ms,
  success: result.success?,
  pr_url: result.pr_url
)
```

**`warn`** — Recoverable errors, degraded functionality, retry attempts

Warn logs indicate potential problems that didn't stop execution but deserve attention. They're useful for detecting patterns: "We're hitting rate limits often" or "Fallback to secondary provider is happening frequently."

Use warn for:

- Rate limits hit (with retry information)
- Fallback to secondary provider or strategy
- Deprecated feature usage
- Unexpected but handled conditions
- Performance degradation

```ruby
Rails.logger.warn(
  message: "github.rate_limited",
  project_id: project.id,
  rate_limit_remaining: 0,
  rate_limit_reset_at: reset_time.iso8601,
  retry_after_seconds: retry_after,
  attempt: current_attempt
)
```

**`error`** — Failures, exceptions, issues requiring attention

Error logs demand investigation. They represent things that shouldn't happen or failures that impact users.

Use error for:

- Unrecoverable failures
- External service errors that weren't handled
- Validation failures that indicate bugs (not user input errors)
- Security-relevant failures (auth failures, permission denials)

```ruby
Rails.logger.error(
  message: "agent_execution.failed",
  agent_run_id: agent_run.id,
  error_class: error.class.name,
  error_message: error.message,
  backtrace: error.backtrace.first(10)
)
```

### When to Log

Log at these critical junctures to create readable execution traces:

| Juncture | Level | What to Include |
|----------|-------|-----------------|
| Method entry (important methods) | debug | Key parameters, initial state |
| State transitions | info | Old state, new state, trigger |
| External interactions | info | Service, operation, key params |
| File operations | debug | Path, operation, size |
| Decision points | debug | Condition evaluated, path taken |
| Loop progress | debug | Current item, total, percentage (throttled) |
| Operation completion | info | Duration, result summary, metrics |
| Errors | error | Error class, message, context, backtrace |
| Retries | warn | Attempt number, reason, delay |

### Logging Implementation

```ruby
class AgentExecutionService
  COMPONENT = "agent_execution"

  def execute(agent_run)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    log_info("started",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      issue_id: agent_run.issue_id,
      agent_type: agent_run.agent_type
    )

    log_debug("checking_budget",
      agent_run_id: agent_run.id,
      budget_remaining_cents: agent_run.project.budget_remaining_cents,
      estimated_cost_cents: estimate_cost(agent_run)
    )

    unless agent_run.project.budget_remaining?
      log_warn("budget_exceeded",
        agent_run_id: agent_run.id,
        budget_remaining_cents: agent_run.project.budget_remaining_cents
      )
      return Result.failure(:budget_exceeded)
    end

    model = select_model(agent_run)
    log_debug("model_selected",
      agent_run_id: agent_run.id,
      model_id: model.id,
      model_name: model.display_name,
      selection_reasoning: model.selection_reasoning
    )

    result = run_agent(agent_run, model)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

    if result.success?
      log_info("completed",
        agent_run_id: agent_run.id,
        iterations: result.iterations,
        tokens_used: result.token_usage.total,
        cost_cents: result.cost_cents,
        duration_ms: elapsed_ms,
        pr_url: result.pr_url
      )
    else
      log_error("failed",
        agent_run_id: agent_run.id,
        error: result.error,
        iterations: result.iterations,
        duration_ms: elapsed_ms
      )
    end

    result
  rescue => e
    log_error("exception",
      agent_run_id: agent_run.id,
      error_class: e.class.name,
      error_message: e.message,
      backtrace: e.backtrace.first(10)
    )
    raise
  end

  private

  def log_debug(action, **metadata)
    Rails.logger.debug(message: "#{COMPONENT}.#{action}", **metadata)
  end

  def log_info(action, **metadata)
    Rails.logger.info(message: "#{COMPONENT}.#{action}", **metadata)
  end

  def log_warn(action, **metadata)
    Rails.logger.warn(message: "#{COMPONENT}.#{action}", **metadata)
  end

  def log_error(action, **metadata)
    Rails.logger.error(message: "#{COMPONENT}.#{action}", **metadata)
  end
end
```

### Metadata Guidelines

**Always include**:

- Identifiers that enable correlation (agent_run_id, project_id, workflow_id)
- Counts and sizes for understanding scale (iteration_count, token_count)
- Timing information for performance analysis (duration_ms, elapsed_seconds)
- Status codes and result types for filtering

**Never include**:

- Secrets, tokens, passwords, API keys
- Full request/response payloads (log sizes or summaries instead)
- PII beyond what's necessary for debugging
- Redundant information already in the message

**Rationale for avoiding secrets**: Log aggregation systems often have broader access than application secrets. Logs persist longer and may be shared for debugging. Auto-redaction is a safety net, not a primary defense—avoid logging secrets in the first place.

### Component Names

Use consistent component names across the codebase for easy filtering:

```
agent_execution    # Running agents
github_sync        # GitHub API interactions
prompt_evolution   # Prompt A/B testing and evolution
container_manager  # Docker container lifecycle
temporal_worker    # Temporal workflow execution
model_selection    # LLM model choosing
secrets_proxy      # API key injection
```

---

## Testing Architecture

### Philosophy

Test behavior and interfaces, not implementation details. Tests should verify that code does what it's supposed to do, not how it does it internally.

**Rationale**: Tests coupled to implementation break when you refactor, even if behavior is unchanged. This makes refactoring expensive and discourages improvement. Tests coupled to behavior remain valid through refactoring and catch actual regressions.

```ruby
# GOOD: Tests behavior
it "creates an agent run with pending status" do
  result = AgentRuns::Create.call(project: project, issue: issue)
  expect(result.agent_run.status).to eq("pending")
end

# BAD: Tests implementation
it "calls AgentRun.create! with correct arguments" do
  expect(AgentRun).to receive(:create!).with(
    project: project,
    issue: issue,
    status: :pending
  )
  AgentRuns::Create.call(project: project, issue: issue)
end
```

### Test Organization

```
spec/
├── models/           # ActiveRecord model specs
├── services/         # Servo service specs
├── workflows/        # Temporal workflow specs (using Temporal test framework)
├── activities/       # Temporal activity specs
├── adapters/         # External adapter specs (heavily mocked)
├── requests/         # Request specs for HTTP endpoints
├── system/           # System specs for full user flows
└── support/          # Shared helpers, factories, configurations
```

**One spec file per class**, path mirrors class path:

- `app/services/agent_runs/create.rb` → `spec/services/agent_runs/create_spec.rb`
- `app/models/agent_run.rb` → `spec/models/agent_run_spec.rb`

**Consolidate related tests** with describe/context blocks rather than spreading across files:

```ruby
RSpec.describe AgentRuns::Create do
  describe "#call" do
    context "with valid inputs" do
      it "creates an agent run" do # ...
      it "returns success" do # ...
    end

    context "when project has no budget" do
      it "returns failure with budget error" do # ...
    end

    context "when issue already has an active run" do
      it "returns failure with duplicate error" do # ...
    end
  end
end
```

### Mocking Strategy

Mock external dependencies. Never mock application code.

**Rationale**: Mocking application code tests your mocks, not your code. It creates false confidence—tests pass but the actual integration might be broken.

```ruby
# GOOD: Mock external service
let(:github_client) { instance_double(Octokit::Client) }
before { allow(Octokit::Client).to receive(:new).and_return(github_client) }

# GOOD: Use dependency injection for external services
let(:service) { described_class.new(github_client: mock_client) }

# BAD: Mocking application code
allow(AgentRuns::Create).to receive(:call).and_return(mock_result)
# This tests nothing about how AgentRuns::Create actually behaves
```

For services that depend on other services, test the integration:

```ruby
# Testing a service that uses another service
RSpec.describe Features::Implement do
  let(:feature_request) { create(:feature_request) }

  it "creates agent runs for each planned task" do
    result = described_class.call(feature_request: feature_request)

    expect(result).to be_success
    expect(AgentRun.count).to eq(result.plan.tasks.count)
  end
end
```

### Coverage Philosophy

Target 85-100% coverage for business logic. Accept pragmatic limits for:

- **External boundaries**: Test your adapter's interface, not the external library's internals
- **Container operations**: Mock Docker interactions, test orchestration logic
- **Temporal workflows**: Use Temporal's testing framework for workflow logic

Document legitimate coverage gaps:

```ruby
# :nocov: - Docker container interaction, tested via integration tests
def start_container(config)
  Docker::Container.create(config).tap(&:start)
end
# :nocov:
```

### Pending Specs Policy

Maintain strict discipline with pending specs:

- **Previously passing specs must NOT become pending**. If a test fails, either fix the code, fix the test, or deliberately delete the test with justification.
- **Pending only for clearly identified future work** with issue reference:

```ruby
# GOOD
pending "supports parallel agent execution (#45)"

# BAD - no tracking, will be forgotten
pending "fix later"
pending "not working"
```

**Rationale**: Pending specs without tracking accumulate and become noise. They represent technical debt that's not tracked anywhere. Requiring issue references ensures the work is visible and prioritized.

---

## Error Handling

### Philosophy

Distinguish between internal errors (bugs) and external errors (expected failures from the outside world).

**Internal errors**: Let them crash. A nil where you expected an object, a missing method, an invalid state—these are bugs. Crashing immediately with a clear error is better than limping along with corrupted state.

**External errors**: Handle gracefully. Network timeouts, rate limits, invalid user input, unavailable services—these are expected. Handle them with specific error types and clear recovery paths.

### Specific Error Types

Never use generic rescue. Create specific error types for different failure modes:

```ruby
module GitHub
  class Error < StandardError; end
  class RateLimitExceeded < Error
    attr_reader :retry_after
    def initialize(retry_after:)
      @retry_after = retry_after
      super("GitHub rate limit exceeded, retry after #{retry_after}s")
    end
  end
  class TokenInvalid < Error; end
  class RepoNotFound < Error; end
  class PermissionDenied < Error; end
end

class GitHubAdapter
  def fetch_issues(repo)
    client.issues(repo)
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn(
      message: "github.rate_limited",
      repo: repo,
      retry_after: e.response_headers["Retry-After"]
    )
    raise GitHub::RateLimitExceeded.new(
      retry_after: e.response_headers["Retry-After"].to_i
    )
  rescue Octokit::Unauthorized
    Rails.logger.error(message: "github.unauthorized", repo: repo)
    raise GitHub::TokenInvalid
  rescue Octokit::NotFound
    raise GitHub::RepoNotFound
  end
end
```

**Rationale**: Specific errors enable specific handling. Code that catches `GitHub::RateLimitExceeded` can retry with backoff. Code that catches `GitHub::TokenInvalid` can prompt for re-authentication. Generic rescue catches everything and handles nothing well.

### Temporal Error Handling

Temporal workflows have their own error handling model. Use retry policies for transient failures:

```ruby
class RunAgentActivity < Paid::Activity
  activity_options(
    start_to_close_timeout: 45.minutes,
    retry_policy: {
      initial_interval: 1.second,
      backoff_coefficient: 2.0,
      max_interval: 1.minute,
      max_attempts: 3,
      # Don't retry these - they won't succeed on retry
      non_retryable_error_types: [
        BudgetExceeded,        # Business rule, not transient
        GitHub::TokenInvalid,   # Auth failure, needs user action
        GuardrailTriggered     # Agent hit limits, needs review
      ]
    }
  )

  def execute(agent_run_id)
    # Implementation
  end
end
```

---

## Rails-Specific Patterns

### Controllers

Controllers should be thin, delegating to services. The controller's job is HTTP concerns: parsing params, authorization, rendering responses.

```ruby
class AgentRunsController < ApplicationController
  include Servo::RailsConcern

  def index
    @agent_runs = policy_scope(AgentRun)
      .includes(:project, :issue)
      .order(created_at: :desc)
      .page(params[:page])
  end

  def show
    @agent_run = current_account.agent_runs.find(params[:id])
    authorize @agent_run
  end

  def create
    authorize AgentRun

    render_servo AgentRuns::Create.call(
      project: current_account.projects.find(params[:project_id]),
      issue: Issue.find(params[:issue_id]),
      agent_type: params[:agent_type]
    )
  end

  def cancel
    @agent_run = current_account.agent_runs.find(params[:id])
    authorize @agent_run

    render_servo AgentRuns::Cancel.call(agent_run: @agent_run)
  end
end
```

### Views with Phlex

Use [Phlex](https://www.phlex.fun/) for view components. Phlex provides pure Ruby views with better performance than ERB and natural composition.

**Why Phlex over ERB/ViewComponent**:

- Pure Ruby: No template language to learn, full IDE support
- Performance: Faster than ERB, especially for component-heavy pages
- Composition: Components compose naturally as Ruby objects
- Type safety: Ruby's type checking applies to your views

```ruby
# app/views/components/agent_run_card.rb
class Components::AgentRunCard < Phlex::HTML
  include Phlex::Rails::Helpers::Routes

  def initialize(agent_run:)
    @agent_run = agent_run
  end

  def view_template
    article(
      class: "agent-run-card",
      data: {
        controller: "agent-run",
        agent_run_id: @agent_run.id,
        status: @agent_run.status
      }
    ) do
      header { render_header }
      section(class: "metrics") { render_metrics } if @agent_run.completed?
      footer { render_actions }
    end
  end

  private

  def render_header
    div(class: "flex justify-between items-center") do
      h3(class: "text-lg font-semibold") { @agent_run.issue.title }
      render Components::StatusBadge.new(status: @agent_run.status)
    end

    p(class: "text-sm text-gray-600 mt-1") do
      "#{@agent_run.agent_type} · Started #{time_ago_in_words(@agent_run.started_at)} ago"
    end
  end

  def render_metrics
    dl(class: "grid grid-cols-3 gap-4") do
      metric("Iterations", @agent_run.iterations)
      metric("Tokens", number_with_delimiter(@agent_run.tokens_total))
      metric("Cost", number_to_currency(@agent_run.cost_cents / 100.0))
    end
  end

  def metric(label, value)
    div do
      dt(class: "text-xs text-gray-500 uppercase") { label }
      dd(class: "text-lg font-semibold") { value.to_s }
    end
  end

  def render_actions
    div(class: "flex gap-2") do
      if @agent_run.running?
        button(
          class: "btn btn-danger",
          data: { action: "agent-run#cancel" }
        ) { "Cancel" }
      end

      if @agent_run.pr_url
        a(href: @agent_run.pr_url, class: "btn btn-primary", target: "_blank") do
          "View PR"
        end
      end
    end
  end
end
```

**Page layouts with Phlex**:

```ruby
# app/views/layouts/application_layout.rb
class Layouts::ApplicationLayout < Phlex::HTML
  include Phlex::Rails::Helpers::CSRFMetaTags
  include Phlex::Rails::Helpers::StylesheetLinkTag
  include Phlex::Rails::Helpers::JavaScriptIncludeTag

  def initialize(title: "Paid")
    @title = title
  end

  def view_template(&block)
    doctype
    html(lang: "en") do
      head do
        meta(charset: "utf-8")
        meta(name: "viewport", content: "width=device-width, initial-scale=1")
        title { @title }
        csrf_meta_tags
        stylesheet_link_tag "application", data: { turbo_track: "reload" }
        javascript_include_tag "application", defer: true, data: { turbo_track: "reload" }
      end

      body(class: "min-h-screen bg-gray-50") do
        render Components::Navbar.new(user: Current.user, account: Current.account)

        main(class: "container mx-auto px-4 py-8", &block)

        render Components::Footer.new
        render Components::FlashMessages.new(flash: flash)
      end
    end
  end
end
```

### Hotwire Integration

Phlex works seamlessly with Turbo. Broadcast updates by rendering components:

```ruby
# app/models/agent_run.rb
class AgentRun < ApplicationRecord
  after_update_commit :broadcast_status_change, if: :saved_change_to_status?

  private

  def broadcast_status_change
    Turbo::StreamsChannel.broadcast_replace_to(
      "project_#{project_id}_agent_runs",
      target: dom_id(self),
      html: Components::AgentRunCard.new(agent_run: self).call
    )
  end
end
```

### Background Processing

**Prefer Temporal workflows** for anything that:

- Takes more than a few seconds
- Needs retry logic
- Involves multiple steps
- Calls external services
- Benefits from observability

**Use GoodJob** only for simple, fire-and-forget tasks:

- Sending emails
- Cache warming
- Simple cleanup
- Metric aggregation

**Why GoodJob over Sidekiq**:

- Uses PostgreSQL (no Redis dependency, one less thing to operate)
- Transactional enqueuing (job commits with your data, no phantom jobs)
- Built-in dashboard
- Cron-like scheduling

```ruby
# config/application.rb
config.active_job.queue_adapter = :good_job

# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :async
  config.good_job.max_threads = 5
  config.good_job.poll_interval = 30
  config.good_job.shutdown_timeout = 25

  # Cron-like scheduling
  config.good_job.cron = {
    metrics_aggregation: {
      cron: "*/15 * * * *",  # Every 15 minutes
      class: "MetricsAggregationJob"
    },
    cleanup: {
      cron: "0 3 * * *",     # Daily at 3am
      class: "CleanupJob"
    }
  }
end
```

---

## Security and Safety

### Never Execute Untrusted Code

Agents run in containers specifically to isolate untrusted code execution. Never execute user-provided or AI-generated code in the main application:

```ruby
# NEVER DO THIS
eval(agent_output)
system(user_provided_command)
`#{params[:command]}`
```

### Validate File Paths

Prevent directory traversal attacks:

```ruby
def safe_path(base_dir, user_path)
  full_path = File.expand_path(user_path, base_dir)

  unless full_path.start_with?(File.expand_path(base_dir))
    raise SecurityError, "Path traversal attempt: #{user_path}"
  end

  full_path
end
```

### Don't Log Secrets

The logging middleware includes auto-redaction for common secret patterns, but this is a safety net. Avoid logging secrets in the first place:

```ruby
# BAD
Rails.logger.info("Calling GitHub with token: #{token}")

# GOOD
Rails.logger.info(
  message: "github.api_call",
  endpoint: endpoint,
  token_prefix: token[0..7] + "..."  # For debugging which token
)
```

---

## Pre-Release Backward Compatibility Policy

Paid is v0.x.x (pre-release) and **deliberately maintains no backward compatibility**. This keeps the codebase clean and enables rapid iteration.

When refactoring:

- Remove old implementations immediately
- Delete deprecated methods in the same commit that introduces replacements
- No legacy wrappers, feature flags for old behavior, or compatibility shims
- Update all callers in the same commit

**Rationale**: Backward compatibility has a cost—complexity, testing burden, documentation confusion. For a pre-release product with a small user base, the cost exceeds the benefit. Users expect breaking changes. Clean, single-path implementations are easier to understand and maintain.

After 1.0, we'll adopt semver and backward compatibility commitments. Until then, move fast.

---

## Performance Guidelines

### Avoid O(n²) Over Large Datasets

Nested loops over large collections are a common source of performance problems:

```ruby
# BAD: O(n²)
issues.each do |issue|
  runs = agent_runs.select { |r| r.issue_id == issue.id }
end

# GOOD: O(n) with index
runs_by_issue = agent_runs.index_by(&:issue_id)
issues.each do |issue|
  runs = runs_by_issue[issue.id]
end
```

### Batch Database Operations

```ruby
# BAD: N+1 queries
issues.each { |issue| AgentRun.create!(issue: issue, status: :pending) }

# GOOD: Single insert
AgentRun.insert_all(
  issues.map { |issue| { issue_id: issue.id, status: :pending } }
)
```

### Use find_each for Large Record Sets

```ruby
# BAD: Loads all records into memory
AgentRun.where(status: :completed).each { |run| process(run) }

# GOOD: Loads in batches
AgentRun.where(status: :completed).find_each { |run| process(run) }
```

### Stream Large Files

```ruby
# BAD: Loads entire file into memory
content = File.read(large_file_path)

# GOOD: Streams line by line
File.foreach(large_file_path) do |line|
  process_line(line)
end
```
