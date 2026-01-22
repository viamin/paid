# Paid Architecture

## System Overview

Paid is composed of four main subsystems that work together to orchestrate AI-driven software development:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PAID SYSTEM                                     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         RAILS APPLICATION                              │ │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │ │
│  │  │   Web UI     │ │  API Layer   │ │  Background  │ │   Database   │  │ │
│  │  │  (Hotwire)   │ │  (Internal)  │ │  Jobs (SJ)   │ │ (PostgreSQL) │  │ │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      TEMPORAL ORCHESTRATION                            │ │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │ │
│  │  │   Temporal   │ │   Workflow   │ │   Activity   │ │   Worker     │  │ │
│  │  │   Server     │ │  Definitions │ │  Definitions │ │   Pool       │  │ │
│  │  │  (External)  │ │              │ │              │ │              │  │ │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      CONTAINER MANAGEMENT                              │ │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │ │
│  │  │   Docker     │ │   Project    │ │  Git         │ │   Secrets    │  │ │
│  │  │   Engine     │ │  Containers  │ │  Worktrees   │ │   Proxy      │  │ │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      EXTERNAL INTEGRATIONS                             │ │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │ │
│  │  │   GitHub     │ │  LLM APIs    │ │  Agent CLIs  │ │  ruby-llm    │  │ │
│  │  │   (PAT)      │ │  (proxied)   │ │  (in-cont.)  │ │  (registry)  │  │ │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

### Core Application
| Component | Technology | Rationale |
|-----------|------------|-----------|
| Framework | Rails 8+ | Mature, productive, excellent for data-heavy apps |
| Database | PostgreSQL | JSON support, reliability, Temporal compatibility |
| Frontend | Hotwire (Turbo + Stimulus) | Real-time UI without SPA complexity |
| Background Jobs | Solid Queue | Rails-native, database-backed |
| Caching | Solid Cache | Rails-native, database-backed |
| WebSockets | Action Cable | Real-time dashboard updates |

### Orchestration
| Component | Technology | Rationale |
|-----------|------------|-----------|
| Workflow Engine | Temporal.io | Durable workflows, built-in retry, observability |
| Temporal Client | temporalio-ruby | Official Ruby SDK |
| Worker Pool | Fixed pool (configurable) | Simplicity first, auto-scale later |

### Agent Execution
| Component | Technology | Rationale |
|-----------|------------|-----------|
| Containers | Docker | Industry standard, aidp compatibility |
| Agent CLIs | Claude Code, Cursor, Codex, GitHub Copilot | Extracted to shared gem |
| API Calls | ruby-llm gem | Model registry, unified interface |
| Isolation | Git worktrees | Parallel work without conflicts |

### External Services
| Component | Technology | Rationale |
|-----------|------------|-----------|
| Source Control | GitHub (PAT) | Projects V2 integration, issue tracking |
| LLM Providers | Anthropic, OpenAI, Google, etc. | Via ruby-llm abstraction |

## Component Details

### 1. Rails Application

The Rails app is the control plane for Paid. It manages:

#### Web UI (Hotwire)
- **Project Management**: Add/remove GitHub repos, configure tokens
- **Agent Dashboard**: Live view of running agents, ability to interrupt
- **Prompt Management**: Version history, A/B test configuration
- **Metrics & Costs**: Per-project token usage, cost tracking
- **Style Guides**: Global and project-specific LLM style guides

#### Data Layer (PostgreSQL)
- All configuration stored as data (prompts, model preferences, thresholds)
- Prompt versioning with full history
- Agent run logs and metrics
- Cost tracking per project/model
- Quality feedback (human votes, automated scores)

#### Background Jobs (Solid Queue)
- GitHub polling (lightweight, frequent)
- Metric aggregation
- Prompt evolution processing
- Container health checks

### 2. Temporal Orchestration

Temporal handles long-running, stateful workflows. The Rails app schedules workflows; Temporal ensures they complete reliably.

#### Workflows

**GitHubPollWorkflow**
- Runs continuously per project
- Checks for labeled issues (configurable labels)
- Triggers planning or execution workflows
- Handles rate limiting gracefully

**PlanningWorkflow**
- Decomposes feature requests into sub-issues
- Creates GitHub Project items
- Assigns issues to appropriate agents
- Handles user input requests

**AgentExecutionWorkflow**
- Selects model via meta-agent
- Provisions container and worktree
- Runs agent activity with monitoring
- Handles retries, timeouts, cost limits
- Creates PR on completion

**PromptEvolutionWorkflow**
- Samples completed agent runs
- Evaluates quality metrics
- Proposes prompt mutations
- Runs A/B tests
- Promotes winning prompts

#### Activities

Activities are the units of work executed by workers:

| Activity | Description |
|----------|-------------|
| `CloneRepositoryActivity` | Clone/fetch repo into container |
| `CreateWorktreeActivity` | Set up isolated worktree for agent |
| `RunAgentActivity` | Execute agent CLI or API call |
| `CreatePullRequestActivity` | Open PR with agent's changes |
| `UpdateIssueActivity` | Update GitHub issue status/labels |
| `EvaluateQualityActivity` | Run quality metrics on agent output |
| `SelectModelActivity` | Meta-agent model selection |

#### Worker Pool

Workers run as separate processes, executing activities:

```
┌─────────────────────────────────────────────────────────────┐
│                     WORKER POOL                              │
│                                                              │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐            │
│  │  Worker 1   │ │  Worker 2   │ │  Worker N   │   ...      │
│  │             │ │             │ │             │            │
│  │ ┌─────────┐ │ │ ┌─────────┐ │ │ ┌─────────┐ │            │
│  │ │Container│ │ │ │Container│ │ │ │Container│ │            │
│  │ │ (Proj A)│ │ │ │ (Proj B)│ │ │ │ (Proj A)│ │            │
│  │ └─────────┘ │ │ └─────────┘ │ │ └─────────┘ │            │
│  └─────────────┘ └─────────────┘ └─────────────┘            │
└─────────────────────────────────────────────────────────────┘
```

Configuration (Phase 1):
- Fixed worker count via environment variable
- Each worker can run one activity at a time
- Workers are stateless; containers are per-activity

### 3. Container Management

Each agent runs in an isolated Docker container with:

#### Container Image
Based on aidp's devcontainer approach:
- Base: Ruby + Node + common dev tools
- Pre-installed: Agent CLIs (Claude Code, Cursor, Codex, Copilot)
- Firewall: Allowlist-only network access
- No secrets: API keys not passed to container

#### Git Worktree Isolation
```
/workspaces/
├── project-a/
│   ├── .git/                    # Shared git directory
│   ├── main/                    # Main branch checkout
│   ├── worktree-agent-1-abc/    # Agent 1's isolated workspace
│   ├── worktree-agent-2-def/    # Agent 2's isolated workspace
│   └── worktree-agent-3-ghi/    # Agent 3's isolated workspace
└── project-b/
    ├── .git/
    ├── main/
    └── worktree-agent-4-jkl/
```

Each agent gets:
- Unique worktree from current main
- Unique branch name
- Complete isolation from other agents
- Cleanup after PR creation

#### Secrets Proxy
Agents need API access but shouldn't have raw keys:

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Agent     │ ──────► │   Secrets   │ ──────► │  LLM API    │
│ (Container) │         │   Proxy     │         │  (External) │
│             │         │   (Paid)    │         │             │
│ No API keys │         │ Adds auth   │         │             │
└─────────────┘         └─────────────┘         └─────────────┘
```

The proxy:
- Runs as part of Paid
- Receives unauthenticated requests from containers
- Adds appropriate API keys
- Forwards to LLM providers
- Logs usage for cost tracking

### 4. External Integrations

#### GitHub (PAT-based)
Initial implementation uses Personal Access Tokens:
- UI guides users through token creation
- Shows required permissions for granular tokens
- Stores tokens encrypted in database

Required permissions:
- `repo`: Full repository access
- `project`: GitHub Projects V2 access (if available)
- `read:org`: Organization membership (for org repos)

Graceful degradation:
- If Projects V2 unavailable, use issues-only workflow
- Track sub-tasks via issue references instead of project items

#### LLM Integration
Two modes of agent execution:

**CLI Mode** (via paid-agents gem):
- Claude Code, Cursor, Codex, GitHub Copilot
- Runs in container with proxied API access
- Output captured for metrics

**API Mode** (via ruby-llm):
- Direct API calls for simpler tasks
- Model registry provides capabilities/costs
- Used by meta-agent for model selection

### 5. Model Selection System

The meta-agent chooses models based on:

```
┌─────────────────────────────────────────────────────────────┐
│                    MODEL SELECTION                           │
│                                                              │
│  ┌─────────────────┐    ┌─────────────────┐                 │
│  │  Task Context   │    │  Model Registry │                 │
│  │  - Complexity   │    │  (ruby-llm)     │                 │
│  │  - Token est.   │    │  - Capabilities │                 │
│  │  - Budget       │    │  - Costs        │                 │
│  │  - History      │    │  - Limits       │                 │
│  └────────┬────────┘    └────────┬────────┘                 │
│           │                      │                           │
│           ▼                      ▼                           │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              META-AGENT (LLM-based)                     ││
│  │                                                          ││
│  │  Fallback: Rules-based selection if meta-agent fails    ││
│  └─────────────────────────────────────────────────────────┘│
│                          │                                   │
│                          ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              SELECTED MODEL + RATIONALE                 ││
│  │              (logged for analysis)                      ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

Rules-based fallback:
1. If budget constrained → cheapest capable model
2. If high complexity → most capable model within budget
3. If similar past task → model that succeeded before
4. Default → configured default model

## Data Flow Examples

### Example 1: Issue to PR

```
1. User labels issue "paid-plan" on GitHub
            │
            ▼
2. GitHubPollWorkflow detects label
            │
            ▼
3. PlanningWorkflow creates sub-issues
            │
            ▼
4. Each sub-issue triggers AgentExecutionWorkflow
            │
            ▼
5. Meta-agent selects model for each task
            │
            ▼
6. Container provisioned, worktree created
            │
            ▼
7. Agent runs (CLI or API mode)
            │
            ▼
8. PR created with changes
            │
            ▼
9. Human reviews and merges (or requests changes)
            │
            ▼
10. Quality metrics collected, prompt evolution triggered
```

### Example 2: Prompt Evolution

```
1. PromptEvolutionWorkflow samples recent agent runs
            │
            ▼
2. EvaluateQualityActivity scores each run:
   - Iteration count
   - Code quality metrics
   - Human feedback (thumbs up/down)
   - PR merge rate
            │
            ▼
3. Prompt evolution agent proposes mutations:
   - Modify underperforming prompts
   - Create variants for A/B testing
            │
            ▼
4. New prompt versions created (not replacing old)
            │
            ▼
5. A/B test assignment updated
            │
            ▼
6. Future runs use test assignments
            │
            ▼
7. After sufficient data, winning prompts promoted
```

## Deployment Architecture

### Development
```
docker-compose up
```
Starts:
- Rails app
- PostgreSQL
- Temporal (server, UI, admin-tools)
- Redis (Action Cable)

### Production (Self-Hosted)
```
┌─────────────────────────────────────────────────────────────┐
│                    PRODUCTION DEPLOYMENT                     │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │   Rails App      │  │   Worker Pool    │                 │
│  │   (web + jobs)   │  │   (N workers)    │                 │
│  └────────┬─────────┘  └────────┬─────────┘                 │
│           │                     │                            │
│           ▼                     ▼                            │
│  ┌──────────────────────────────────────────────────────────│
│  │              Temporal Server                              │
│  │        (self-hosted or Temporal Cloud)                   │
│  └──────────────────────────────────────────────────────────│
│                          │                                   │
│                          ▼                                   │
│  ┌──────────────────────────────────────────────────────────│
│  │              PostgreSQL                                   │
│  │        (shared by Rails + Temporal)                      │
│  └──────────────────────────────────────────────────────────│
│                          │                                   │
│                          ▼                                   │
│  ┌──────────────────────────────────────────────────────────│
│  │              Docker Host(s)                               │
│  │        (for agent containers)                            │
│  └──────────────────────────────────────────────────────────│
└─────────────────────────────────────────────────────────────┘
```

## Multi-Tenancy Preparation

While Phase 1 is single-team, the architecture supports future multi-tenancy:

| Concern | Current | Multi-Tenant Ready |
|---------|---------|-------------------|
| Data isolation | Single database | Schema per tenant or row-level security |
| Secrets | Single encrypted store | Per-tenant encryption keys |
| Containers | Shared Docker host | Per-tenant container quotas |
| Temporal | Shared namespace | Per-tenant namespaces |
| Billing | Per-project tracking | Per-tenant aggregation |

The key is that everything is already per-project, and tenants own projects.

## Performance Considerations

### Scaling Bottlenecks (in order of likely impact)

1. **Worker pool size**: More workers = more parallel agents
2. **Container startup time**: Consider pre-warmed containers
3. **GitHub API rate limits**: Implement backoff, caching
4. **LLM API latency**: Async where possible, timeouts configured
5. **Database connections**: Connection pooling, read replicas if needed

### Monitoring Points

- Worker queue depth (Temporal metrics)
- Container startup latency
- API call latency (GitHub, LLM providers)
- Cost per project (trending)
- Prompt A/B test statistical significance

## Security Model

See [SECURITY.md](./SECURITY.md) for detailed security architecture.

Key points:
- Containers are isolated and have no secrets
- All API access proxied through Paid
- GitHub tokens encrypted at rest
- Agents cannot merge PRs
- Network allowlisting in containers
