# RDR-001: Web Framework Selection

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Integration tests for Rails controllers, Hotwire functionality

## Problem Statement

Paid needs a web application framework to serve as its control plane. The framework must support:

1. A real-time dashboard showing agent status and allowing user interrupts
2. CRUD interfaces for managing projects, prompts, and configurations
3. Background job scheduling for GitHub polling and metric aggregation
4. WebSocket support for live updates
5. Database-backed configuration storage (the "Bitter Lesson" principle)
6. Multi-tenant data isolation from day one
7. Integration with Temporal.io for workflow orchestration

The framework choice affects developer productivity, ecosystem access, deployment complexity, and long-term maintainability.

## Context

### Background

Paid is a Platform for AI Development that orchestrates AI agents to build software. It's inspired by [aidp](https://github.com/viamin/aidp), a CLI tool, but adds a web UI for management and a more sophisticated orchestration layer.

The team has Ruby expertise and values developer productivity. The application is data-heavy with complex domain models (prompts, versions, A/B tests, quality metrics) and requires real-time features for the live dashboard.

### Technical Environment

- Target deployment: Self-hosted initially, potentially SaaS later
- Database: PostgreSQL (decided separately in RDR-003)
- Workflow engine: Temporal.io (decided separately in RDR-002)
- Real-time requirements: Live agent status, interrupt capability
- Authentication: Standard user auth with RBAC (rolify/pundit)

## Research Findings

### Investigation Process

1. Evaluated Rails 8 features and defaults
2. Compared with alternatives (Phoenix/Elixir, Django, Next.js)
3. Reviewed ecosystem for required integrations (Temporal, GitHub, LLM providers)
4. Analyzed real-time capabilities (Hotwire vs. alternatives)
5. Assessed multi-tenancy patterns in each framework

### Key Discoveries

**Rails 8 Advantages:**

1. **Solid Queue & Solid Cache**: Native background jobs and caching backed by PostgreSQL. Reduces infrastructure complexity by avoiding Redis for basic needs.

   ```ruby
   # config/database.yml
   production:
     primary:
       <<: *default
     queue:
       <<: *default
       migrations_paths: db/queue_migrate
     cache:
       <<: *default
       migrations_paths: db/cache_migrate
   ```

2. **Hotwire (Turbo + Stimulus)**: Server-rendered HTML with SPA-like interactivity. Perfect for the live dashboard without JavaScript framework complexity.

   ```ruby
   # Broadcasting agent status updates
   class AgentRun < ApplicationRecord
     after_update_commit -> { broadcast_replace_to "agent_runs" }
   end
   ```

3. **Action Cable**: Built-in WebSocket support, integrates cleanly with Hotwire for real-time updates.

4. **Encrypted Attributes**: Native encryption for sensitive data like GitHub tokens.

   ```ruby
   class GithubToken < ApplicationRecord
     encrypts :token, deterministic: false
   end
   ```

5. **Strong ecosystem**: Gems exist for all required integrations:
   - `temporalio-ruby`: Official Temporal SDK
   - `octokit`: GitHub API
   - `ruby-llm`: LLM provider abstraction
   - `rolify` + `pundit`: RBAC
   - `phlex-rails`: Modern view components (preferred over ViewComponents)

**Framework Comparison:**

| Feature | Rails 8 | Phoenix/Elixir | Django | Next.js |
|---------|---------|----------------|--------|---------|
| Real-time | Hotwire + Action Cable | LiveView (excellent) | Channels (add-on) | Requires separate solution |
| Background jobs | Solid Queue (native) | Oban (excellent) | Celery (add-on) | External service |
| ORM | Active Record | Ecto | Django ORM | Prisma (separate) |
| Temporal SDK | Official Ruby SDK | No official SDK | Official Python SDK | Official TypeScript SDK |
| Team expertise | High | Low | Medium | Medium |
| Development speed | High | Medium | High | Medium |

**Temporal SDK Consideration:**

The `temporalio-ruby` gem is the official Ruby SDK maintained by Temporal. This is crucial because workflow code must be written in the same language as the SDK.

```ruby
# Example Temporal workflow in Ruby
class AgentExecutionWorkflow
  workflow_query_attr :status

  def execute(issue_id)
    @status = "starting"
    issue = activity.fetch_issue(issue_id)

    @status = "running"
    result = activity.run_agent(issue: issue)

    @status = "completed"
    result
  end
end
```

**Phoenix/Elixir Consideration:**

Phoenix with LiveView offers superior real-time capabilities, but:
- No official Temporal SDK (would need gRPC bindings or sidecar pattern)
- Team lacks Elixir expertise
- Migration cost outweighs benefits for this use case

## Proposed Solution

### Approach

Use **Rails 8+** with:
- **Hotwire** (Turbo + Stimulus) for real-time UI
- **Action Cable** for WebSocket connections
- **Solid Queue** for lightweight background jobs (GitHub polling, metric aggregation)
- **Temporal** for durable workflows (agent execution, prompt evolution)
- **Phlex** for view components
- **PostgreSQL** as the single datastore

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RAILS APPLICATION                                  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                              WEB LAYER                                   ││
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                 ││
│  │  │  Controllers  │ │ Phlex Views   │ │ Action Cable  │                 ││
│  │  │  + Pundit     │ │ + Hotwire     │ │ Channels      │                 ││
│  │  └───────────────┘ └───────────────┘ └───────────────┘                 ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                           SERVICE LAYER                                  ││
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                 ││
│  │  │ Servo Services│ │ Temporal      │ │ GitHub        │                 ││
│  │  │               │ │ Client        │ │ Client        │                 ││
│  │  └───────────────┘ └───────────────┘ └───────────────┘                 ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                            DATA LAYER                                    ││
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                 ││
│  │  │ Active Record │ │ Solid Queue   │ │ Solid Cache   │                 ││
│  │  │ Models        │ │ Jobs          │ │               │                 ││
│  │  └───────────────┘ └───────────────┘ └───────────────┘                 ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                              PostgreSQL                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Team productivity**: Ruby/Rails expertise means faster development
2. **Ecosystem**: All required integrations have mature gems
3. **Real-time**: Hotwire + Action Cable provides excellent real-time without SPA complexity
4. **Temporal**: Official Ruby SDK enables writing workflows in Ruby
5. **Simplicity**: Solid Queue/Cache reduce infrastructure (no Redis required for basic cases)
6. **Convention over configuration**: Rails conventions accelerate development

### Implementation Example

```ruby
# app/controllers/agent_runs_controller.rb
class AgentRunsController < ApplicationController
  def show
    @agent_run = current_account.agent_runs.find(params[:id])
    authorize @agent_run
  end

  def interrupt
    @agent_run = current_account.agent_runs.find(params[:id])
    authorize @agent_run

    InterruptAgentService.call(agent_run: @agent_run)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @agent_run }
    end
  end
end

# app/views/agent_runs/show.html.erb
<%= turbo_stream_from @agent_run %>

<%= render AgentRunStatusComponent.new(agent_run: @agent_run) %>
```

## Alternatives Considered

### Alternative 1: Phoenix/Elixir

**Description**: Use Phoenix framework with LiveView for real-time UI

**Pros**:
- Superior real-time capabilities with LiveView
- Excellent concurrency model (BEAM VM)
- Growing ecosystem

**Cons**:
- No official Temporal SDK
- Team lacks Elixir expertise
- Smaller ecosystem for required integrations
- Learning curve delays delivery

**Reason for rejection**: No official Temporal SDK is a blocker. Would require either: (a) maintaining unofficial bindings, (b) sidecar pattern adding complexity, or (c) switching workflow engine. Team expertise gap adds risk.

### Alternative 2: Django + HTMX

**Description**: Use Django with HTMX for interactive UI

**Pros**:
- Official Temporal Python SDK
- Strong ORM, good admin interface
- HTMX provides similar benefits to Hotwire

**Cons**:
- Team has less Python expertise than Ruby
- Django Channels (WebSocket) is more complex than Action Cable
- Less convention-driven than Rails

**Reason for rejection**: While Temporal Python SDK is excellent, the team's Ruby expertise and Rails conventions provide faster development velocity.

### Alternative 3: Next.js + TypeScript

**Description**: Full-stack TypeScript with Next.js

**Pros**:
- Official Temporal TypeScript SDK
- Modern frontend tooling
- Strong typing throughout

**Cons**:
- Requires separate backend or API routes for complex logic
- Real-time requires additional setup (Socket.io or similar)
- More infrastructure complexity
- Database interaction less elegant than Active Record

**Reason for rejection**: Adds complexity without clear benefit. Rails provides equivalent functionality with less moving parts.

## Trade-offs and Consequences

### Positive Consequences

- **Fast development**: Rails conventions and team expertise enable rapid iteration
- **Unified codebase**: Workflows, web UI, and background jobs all in Ruby
- **Mature ecosystem**: Battle-tested gems for all integrations
- **Reduced infrastructure**: Solid Queue/Cache mean no Redis dependency initially
- **Real-time built-in**: Hotwire + Action Cable work out of the box

### Negative Consequences

- **Ruby performance**: Ruby is slower than Go/Rust for compute-intensive tasks (mitigated: agents run in containers, not Rails)
- **Scaling complexity**: Rails scaling requires more infrastructure than some alternatives
- **Limited async**: Ruby's async story is weaker than Elixir's (mitigated: Temporal handles long-running work)

### Risks and Mitigations

- **Risk**: Rails monolith becomes unwieldy as features grow
  **Mitigation**: Use Servo services for business logic encapsulation; Temporal handles complex workflows outside Rails

- **Risk**: Ruby performance bottleneck
  **Mitigation**: Heavy compute (agent execution) happens in containers, not Rails. Rails is just the control plane.

- **Risk**: Real-time features don't scale
  **Mitigation**: Action Cable can be backed by Redis for horizontal scaling when needed

## Implementation Plan

### Prerequisites

- [ ] Ruby 3.3+ installed
- [ ] PostgreSQL 15+ available
- [ ] Temporal server accessible (see RDR-002)

### Step-by-Step Implementation

#### Step 1: Rails Application Setup

```bash
rails new paid \
  --database=postgresql \
  --css=tailwind \
  --skip-test \
  --skip-jbuilder

cd paid
bundle add phlex-rails
bundle add servo
bundle add temporalio
bundle add octokit
bundle add ruby-llm
bundle add rolify pundit
```

#### Step 2: Configure Solid Queue

```ruby
# config/application.rb
config.active_job.queue_adapter = :solid_queue
```

#### Step 3: Set Up Action Cable

```ruby
# config/cable.yml
development:
  adapter: async

production:
  adapter: solid_cable
```

#### Step 4: Configure Hotwire

Already included in Rails 8. Ensure Turbo and Stimulus are properly imported in `application.js`.

### Files to Modify

- `Gemfile` - Add required gems
- `config/application.rb` - Configure Active Job adapter
- `config/database.yml` - Configure multiple databases for Solid Queue
- `config/cable.yml` - Configure Action Cable
- `app/javascript/application.js` - Import Turbo and Stimulus

### Dependencies

New gem dependencies:
- `phlex-rails` (~> 2.0)
- `servo` (~> 0.1)
- `temporalio` (~> 0.2)
- `octokit` (~> 9.0)
- `ruby-llm` (~> 1.0)
- `rolify` (~> 6.0)
- `pundit` (~> 2.0)

## Validation

### Testing Approach

1. Request specs for all controller actions
2. System specs for critical user flows (Capybara + Cuprite)
3. Channel specs for Action Cable functionality
4. Integration specs for Temporal workflow triggering

### Test Scenarios

1. **Scenario**: User views live agent dashboard
   **Expected Result**: Agent status updates appear in real-time via Turbo Streams

2. **Scenario**: User interrupts running agent
   **Expected Result**: Interrupt signal sent to Temporal, UI updates to show interrupted status

3. **Scenario**: Multiple users view same agent run
   **Expected Result**: All users see real-time updates simultaneously

### Performance Validation

- Dashboard should load in < 500ms
- Real-time updates should appear within 100ms of state change
- Support 100 concurrent WebSocket connections per Rails process

### Security Validation

- Pundit policies enforced on all controller actions
- CSRF protection enabled
- Account-scoped queries prevent cross-tenant data access

## References

### Requirements & Standards

- [The Bitter Lesson](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf) - Configuration as data principle
- Paid VISION.md - Core principles and requirements

### Dependencies

- [Rails 8 Release Notes](https://guides.rubyonrails.org/8_0_release_notes.html)
- [Hotwire Documentation](https://hotwired.dev/)
- [Solid Queue Repository](https://github.com/rails/solid_queue)
- [temporalio-ruby SDK](https://github.com/temporalio/sdk-ruby)
- [Phlex Documentation](https://www.phlex.fun/)

### Research Resources

- Rails 8 default stack analysis
- Temporal SDK language comparison
- Real-time web framework benchmarks

## Notes

- Consider adding Redis later if Action Cable scaling becomes an issue
- The Temporal worker processes run separately from Rails but share the Ruby codebase
- Evaluate Kamal for deployment (Rails 8's recommended deployment tool)
