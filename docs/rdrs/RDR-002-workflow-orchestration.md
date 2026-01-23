# RDR-002: Workflow Orchestration with Temporal.io

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Workflow integration tests, activity unit tests

## Problem Statement

Paid orchestrates AI agents that perform long-running, stateful operations:

1. **GitHub polling**: Continuously monitor repos for labeled issues
2. **Planning workflows**: Decompose features into sub-issues
3. **Agent execution**: Run AI agents in containers (minutes to hours)
4. **Prompt evolution**: Sample runs, analyze quality, generate mutations, run A/B tests

These workflows have specific requirements:

- **Durability**: Must survive process restarts, deployments, crashes
- **Retries**: Transient failures (API rate limits, network issues) should retry automatically
- **Observability**: Need visibility into workflow state, timing, failures
- **Timeouts**: Long-running activities need bounded execution times
- **Cancellation**: Users must be able to interrupt running agents
- **Parallelism**: Multiple agents can work on different issues simultaneously

Standard background jobs (Sidekiq, Solid Queue) can handle simple tasks but lack the durability and state management needed for complex, long-running workflows.

## Context

### Background

Paid's workflows can run for extended periods:
- Agent execution: 1-60 minutes
- GitHub polling: Runs continuously
- Prompt evolution: Days (waiting for A/B test data)

The system must handle:
- Process crashes mid-workflow
- Deployments during execution
- Network partitions
- API rate limiting
- User-requested cancellations

### Technical Environment

- Language: Ruby (see RDR-001)
- Database: PostgreSQL
- Deployment: Docker containers, self-hosted initially
- Scale: 5-50 concurrent agent runs initially

## Research Findings

### Investigation Process

1. Evaluated Temporal.io architecture and Ruby SDK
2. Compared with alternatives (Sidekiq, GoodJob, custom state machines)
3. Reviewed Temporal's consistency guarantees and failure modes
4. Analyzed integration patterns with Rails applications
5. Studied aidp's approach to long-running operations

### Key Discoveries

**Temporal Architecture:**

Temporal provides durable execution through event sourcing:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TEMPORAL ARCHITECTURE                                 │
│                                                                              │
│  ┌─────────────┐         ┌─────────────┐         ┌─────────────┐           │
│  │   Rails     │ ──────► │  Temporal   │ ◄────── │   Workers   │           │
│  │   App       │  start  │   Server    │  poll   │   (Ruby)    │           │
│  │             │  cancel │             │         │             │           │
│  └─────────────┘         └──────┬──────┘         └─────────────┘           │
│                                 │                                           │
│                                 ▼                                           │
│                          ┌─────────────┐                                   │
│                          │ PostgreSQL  │                                   │
│                          │ (history)   │                                   │
│                          └─────────────┘                                   │
│                                                                              │
│  Key concepts:                                                              │
│  • Workflows: Durable functions that survive failures                       │
│  • Activities: Units of work (API calls, container ops)                    │
│  • Workers: Processes that execute workflows and activities                 │
│  • Task Queues: Route work to appropriate workers                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Durability Mechanism:**

Temporal records every workflow decision as events. On worker restart, workflows replay from history:

```ruby
class AgentExecutionWorkflow
  def execute(issue_id)
    # This code may run multiple times during replays
    # But activities only execute once (results are cached)

    issue = activity.fetch_issue(issue_id)  # Cached after first execution
    container = activity.provision_container(issue.project_id)  # Cached

    result = activity.run_agent(container: container, issue: issue)  # Cached

    activity.create_pull_request(result: result)  # Cached
  end
end
```

**Ruby SDK (`temporalio-ruby`):**

The official Ruby SDK provides:

```ruby
require 'temporalio'

# Define activities
class AgentActivities
  include Temporalio::Activities

  activity
  def fetch_issue(issue_id)
    Issue.find(issue_id).as_json
  end

  activity(start_to_close_timeout: 45.minutes)
  def run_agent(container:, issue:)
    AgentRunner.new(container, issue).execute
  end
end

# Define workflow
class AgentExecutionWorkflow
  include Temporalio::Workflow

  workflow_query_attr :status

  def execute(issue_id)
    @status = "starting"

    issue = activities.fetch_issue(issue_id)
    container = activities.provision_container(issue[:project_id])

    @status = "running"
    result = activities.run_agent(container: container, issue: issue)

    @status = "completed"
    result
  end
end

# Start from Rails
client = Temporalio::Client.connect("localhost:7233")
client.start_workflow(
  AgentExecutionWorkflow,
  123,  # issue_id
  id: "agent-exec-issue-123",
  task_queue: "paid-agents"
)
```

**Comparison with Alternatives:**

| Feature | Temporal | Sidekiq Pro | GoodJob | Custom State Machine |
|---------|----------|-------------|---------|---------------------|
| Durability | Event-sourced | Redis-backed | DB-backed | Manual |
| Long-running (hours) | Native | Awkward | Possible | Complex |
| Workflow composition | Native | Manual | Manual | Manual |
| Retries | Configurable | Basic | Basic | Manual |
| Timeouts | Per-activity | Job-level | Job-level | Manual |
| Cancellation | Native | Limited | Limited | Manual |
| Observability | Temporal UI | Web UI | Dashboard | Custom |
| Child workflows | Native | N/A | N/A | N/A |

**Temporal vs. GoodJob:**

GoodJob is excellent for simple background jobs but lacks:
- Workflow composition (workflows calling other workflows)
- Activity-level timeouts within a job
- Built-in cancellation propagation
- Event-sourced durability (GoodJob relies on job table, not event log)

For agent execution workflows that may run for 30+ minutes with multiple activities, Temporal's model is more appropriate.

**Deployment Options:**

1. **Self-hosted Temporal**: Run Temporal server alongside Paid
2. **Temporal Cloud**: Managed service (adds cost, removes ops burden)

For initial deployment, self-hosted with Docker Compose is simplest. Can migrate to Temporal Cloud later.

```yaml
# docker-compose.yml (excerpt)
services:
  temporal:
    image: temporalio/auto-setup:1.24
    ports:
      - "7233:7233"
    environment:
      - DB=postgres12
      - DB_PORT=5432
      - POSTGRES_USER=temporal
      - POSTGRES_PWD=temporal
      - POSTGRES_SEEDS=postgres
    depends_on:
      - postgres

  temporal-ui:
    image: temporalio/ui:2.26
    ports:
      - "8080:8080"
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
```

## Proposed Solution

### Approach

Use **Temporal.io** with the official Ruby SDK for all long-running, stateful workflows:

1. **GitHubPollWorkflow**: Continuous polling per project
2. **PlanningWorkflow**: Feature decomposition
3. **AgentExecutionWorkflow**: Agent runs in containers
4. **PromptEvolutionWorkflow**: Quality analysis and prompt mutation

Use **GoodJob** (PostgreSQL-backed) for lightweight, non-critical background jobs:
- Metric aggregation
- Email notifications
- Cache warming
- Cleanup tasks

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WORKFLOW ARCHITECTURE                                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         RAILS APPLICATION                                ││
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                 ││
│  │  │  Web UI       │ │ Temporal      │ │ GoodJob       │                 ││
│  │  │  Controllers  │ │ Client        │ │ (lightweight) │                 ││
│  │  └───────────────┘ └───────────────┘ └───────────────┘                 ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│            │                    │                    │                       │
│            │                    ▼                    ▼                       │
│            │         ┌─────────────────┐   ┌─────────────────┐              │
│            │         │ Temporal Server │   │ PostgreSQL      │              │
│            │         └────────┬────────┘   │ (job queue)     │              │
│            │                  │            └─────────────────┘              │
│            │                  │                                              │
│            │                  ▼                                              │
│            │         ┌─────────────────────────────────────────┐            │
│            │         │           WORKER POOL                    │            │
│            │         │                                          │            │
│            │         │  ┌───────────┐ ┌───────────┐            │            │
│            │         │  │ Worker 1  │ │ Worker N  │  ...       │            │
│            │         │  │           │ │           │            │            │
│            │         │  │ ┌───────┐ │ │ ┌───────┐ │            │            │
│            │         │  │ │Docker │ │ │ │Docker │ │            │            │
│            │         │  │ │Agent  │ │ │ │Agent  │ │            │            │
│            │         │  │ └───────┘ │ │ └───────┘ │            │            │
│            │         │  └───────────┘ └───────────┘            │            │
│            │         └─────────────────────────────────────────┘            │
│            │                                                                 │
│            └───────────────► Dashboard (Action Cable)                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Durability**: Temporal survives crashes; workflows resume automatically
2. **Composition**: Workflows can call child workflows (planning → multiple executions)
3. **Observability**: Temporal UI provides deep visibility into workflow state
4. **Timeouts**: Per-activity timeouts prevent runaway operations
5. **Cancellation**: Native support for user-initiated interrupts
6. **Official SDK**: Ruby SDK maintained by Temporal team

### Implementation Example

```ruby
# app/workflows/agent_execution_workflow.rb
class AgentExecutionWorkflow
  include Temporalio::Workflow

  workflow_query_attr :status, :iterations, :tokens_used

  def execute(issue_id, options = {})
    @status = "initializing"
    @iterations = 0
    @tokens_used = 0

    # Check budget before starting
    unless activities.check_budget(issue_id)
      @status = "budget_exceeded"
      return { status: :budget_exceeded }
    end

    # Provision resources
    @status = "provisioning"
    container = activities.provision_container(issue_id)
    worktree = activities.create_worktree(container_id: container[:id])

    begin
      # Run agent with monitoring
      @status = "running"
      result = activities.run_agent(
        container_id: container[:id],
        worktree_path: worktree[:path],
        issue_id: issue_id,
        max_iterations: options[:max_iterations] || 10
      )

      @iterations = result[:iterations]
      @tokens_used = result[:tokens_used]

      if result[:success]
        @status = "creating_pr"
        pr = activities.create_pull_request(
          worktree_path: worktree[:path],
          issue_id: issue_id,
          result: result
        )

        @status = "completed"
        { status: :success, pr_url: pr[:url] }
      else
        @status = "failed"
        { status: :failed, error: result[:error] }
      end

    ensure
      # Always clean up
      activities.cleanup_worktree(worktree[:path]) if worktree
      activities.release_container(container[:id]) if container
    end
  end
end

# app/activities/agent_activities.rb
class AgentActivities
  include Temporalio::Activities

  activity(start_to_close_timeout: 30.seconds)
  def check_budget(issue_id)
    issue = Issue.find(issue_id)
    project = issue.project

    budget = project.cost_budget
    return true unless budget&.daily_limit_cents

    budget.current_daily_cents < budget.daily_limit_cents
  end

  activity(
    start_to_close_timeout: 45.minutes,
    heartbeat_timeout: 1.minute,
    retry_policy: {
      maximum_attempts: 3,
      non_retryable_errors: [AgentMonitor::LimitExceeded, BudgetExceeded]
    }
  )
  def run_agent(container_id:, worktree_path:, issue_id:, max_iterations:)
    container = Container.find(container_id)
    issue = Issue.find(issue_id)

    agent = PaidAgents.adapter_for(container.agent_type)

    agent.execute(
      container: container,
      worktree_path: worktree_path,
      issue: issue,
      max_iterations: max_iterations,
      on_heartbeat: -> { Temporalio::Activity.heartbeat }
    )
  end
end
```

## Alternatives Considered

### Alternative 1: GoodJob for Everything

**Description**: Use GoodJob (PostgreSQL-backed) for all background work including long-running agent execution

**Pros**:
- Single technology, simpler deployment
- Native Rails/Active Job integration
- Good PostgreSQL integration

**Cons**:
- Not designed for 30+ minute jobs
- No workflow composition
- Manual state machine for multi-step workflows
- Limited cancellation support
- No event-sourced durability

**Reason for rejection**: Agent execution workflows can run 30+ minutes with multiple distinct phases. GoodJob would require building custom state machine, retry logic, and cancellation handling that Temporal provides natively.

### Alternative 2: Sidekiq Pro with Batches

**Description**: Use Sidekiq Pro's batch feature for workflow composition

**Pros**:
- Mature, battle-tested
- Good performance
- Batch support for dependencies

**Cons**:
- Redis dependency
- Batches are simpler than Temporal workflows
- Still requires custom state management
- Pro license cost
- No event-sourced durability

**Reason for rejection**: Sidekiq batches provide job dependencies but not true workflow composition. Would still need significant custom code for the durability guarantees Paid requires.

### Alternative 3: Custom State Machine

**Description**: Build custom workflow engine using database-backed state machine

**Pros**:
- Full control
- No external dependencies
- Can optimize for specific needs

**Cons**:
- Significant development effort
- Must solve durability, retries, timeouts, cancellation
- Testing complexity
- Maintenance burden

**Reason for rejection**: Building a reliable workflow engine is a major undertaking. Temporal has solved these problems and is actively maintained. Development time is better spent on Paid's core value.

### Alternative 4: AWS Step Functions

**Description**: Use AWS Step Functions for workflow orchestration

**Pros**:
- Managed service
- Good durability
- Visual workflow builder

**Cons**:
- AWS lock-in
- State machine definition separate from code
- Limited Ruby integration
- Cost at scale
- Not self-hostable

**Reason for rejection**: Requires AWS infrastructure. Paid should be self-hostable. Temporal offers similar capabilities without cloud lock-in.

## Trade-offs and Consequences

### Positive Consequences

- **Durability guaranteed**: Workflows survive crashes, deployments, restarts
- **Automatic retries**: Transient failures handled without custom code
- **Composable workflows**: Complex multi-stage operations cleanly expressed
- **Native cancellation**: User interrupts propagate correctly
- **Built-in observability**: Temporal UI shows workflow state, history, timing
- **Scalable**: Add workers to increase throughput

### Negative Consequences

- **Operational complexity**: Another service to deploy and monitor
- **Learning curve**: Team must learn Temporal concepts
- **Debugging complexity**: Replay semantics can be confusing initially
- **Resource usage**: Temporal server requires resources (PostgreSQL, memory)

### Risks and Mitigations

- **Risk**: Temporal becomes single point of failure
  **Mitigation**: Temporal is designed for high availability; run multiple server replicas in production. Can also fall back to Temporal Cloud.

- **Risk**: Team struggles with Temporal concepts
  **Mitigation**: Start with simple workflows, document patterns, pair programming on initial implementation.

- **Risk**: Workflow versioning complexity as code evolves
  **Mitigation**: Follow Temporal's versioning best practices, use workflow patching for backward compatibility.

## Implementation Plan

### Prerequisites

- [ ] Docker and Docker Compose installed
- [ ] PostgreSQL available (can share with Rails or separate)
- [ ] Ruby 3.3+ with temporalio gem installed

### Step-by-Step Implementation

#### Step 1: Deploy Temporal Server

```yaml
# docker-compose.yml
services:
  temporal:
    image: temporalio/auto-setup:1.24
    environment:
      - DB=postgres12
      - POSTGRES_SEEDS=postgres
      - POSTGRES_USER=temporal
      - POSTGRES_PWD=temporal
      - DYNAMIC_CONFIG_FILE_PATH=/etc/temporal/dynamicconfig.yaml
    volumes:
      - ./temporal-config/dynamicconfig.yaml:/etc/temporal/dynamicconfig.yaml
    depends_on:
      - postgres
    ports:
      - "7233:7233"

  temporal-ui:
    image: temporalio/ui:2.26
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
    ports:
      - "8080:8080"
```

#### Step 2: Configure Rails Temporal Client

```ruby
# config/initializers/temporal.rb
require 'temporalio'

Rails.application.config.to_prepare do
  Paid::TemporalClient.configure do |config|
    config.address = ENV.fetch('TEMPORAL_ADDRESS', 'localhost:7233')
    config.namespace = ENV.fetch('TEMPORAL_NAMESPACE', 'default')
    config.task_queue = ENV.fetch('TEMPORAL_TASK_QUEUE', 'paid-agents')
  end
end

# lib/paid/temporal_client.rb
module Paid
  class TemporalClient
    class << self
      attr_accessor :configuration

      def configure
        self.configuration ||= Configuration.new
        yield(configuration)
      end

      def instance
        @instance ||= Temporalio::Client.connect(
          configuration.address,
          namespace: configuration.namespace
        )
      end
    end

    class Configuration
      attr_accessor :address, :namespace, :task_queue
    end
  end
end
```

#### Step 3: Create Worker Process

```ruby
# bin/temporal-worker
#!/usr/bin/env ruby
require_relative "../config/environment"

worker = Temporalio::Worker.new(
  client: Paid::TemporalClient.instance,
  task_queue: Paid::TemporalClient.configuration.task_queue,
  workflows: [
    GitHubPollWorkflow,
    PlanningWorkflow,
    AgentExecutionWorkflow,
    PromptEvolutionWorkflow
  ],
  activities: AgentActivities.new
)

puts "Starting Temporal worker on queue: #{Paid::TemporalClient.configuration.task_queue}"
worker.run
```

#### Step 4: Configure GoodJob for Lightweight Jobs

```ruby
# config/application.rb
config.active_job.queue_adapter = :good_job

# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :async
  config.good_job.queues = 'default:5;metrics:2;notifications:1'
  config.good_job.poll_interval = 5
end
```

### Files to Modify

- `docker-compose.yml` - Add Temporal services
- `Gemfile` - Add `temporalio` and `good_job` gems
- `config/initializers/temporal.rb` - Temporal client configuration
- `config/initializers/good_job.rb` - GoodJob configuration
- `bin/temporal-worker` - Worker process script
- `app/workflows/` - Workflow definitions (new directory)
- `app/activities/` - Activity definitions (new directory)

### Dependencies

- `temporalio` (~> 0.2) - Official Temporal Ruby SDK
- `good_job` (~> 4.0) - PostgreSQL-backed Active Job backend
- Temporal server (Docker image)
- Temporal UI (Docker image, optional but recommended)

## Validation

### Testing Approach

1. **Workflow unit tests**: Test workflow logic with mocked activities
2. **Activity unit tests**: Test activity implementations in isolation
3. **Integration tests**: End-to-end workflow execution with test Temporal server
4. **Replay tests**: Verify workflows handle restarts correctly

### Test Scenarios

1. **Scenario**: Agent execution workflow completes successfully
   **Expected Result**: PR created, workflow status is "completed"

2. **Scenario**: Activity fails transiently
   **Expected Result**: Activity retries automatically, workflow completes

3. **Scenario**: User cancels running workflow
   **Expected Result**: Cleanup activities run, workflow status is "cancelled"

4. **Scenario**: Worker crashes mid-workflow
   **Expected Result**: On restart, workflow resumes from last checkpoint

### Performance Validation

- Workflow start latency < 100ms
- Activity dispatch latency < 50ms
- Support 50 concurrent workflows per worker
- Temporal history size reasonable (< 1000 events per workflow)

### Security Validation

- Temporal server not exposed to public internet
- Workflow inputs validated before execution
- Activities run with appropriate timeout/resource limits

## References

### Requirements & Standards

- Paid ARCHITECTURE.md - Workflow requirements
- Paid AGENT_SYSTEM.md - Agent execution workflow details

### Dependencies

- [Temporal Ruby SDK](https://github.com/temporalio/sdk-ruby)
- [Temporal Documentation](https://docs.temporal.io/)
- [Temporal Server Docker](https://hub.docker.com/r/temporalio/auto-setup)
- [GoodJob Documentation](https://github.com/bensheldon/good_job)

### Research Resources

- Temporal architecture deep dive
- Event sourcing in workflow systems
- Temporal vs. alternatives comparison

## Notes

- Monitor Temporal server resource usage in production
- Consider Temporal Cloud for production if ops burden is high
- Workflow versioning will be important as the system evolves
- The Temporal UI (port 8080) is invaluable for debugging workflows
