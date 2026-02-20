# Paid Roadmap

This document outlines the phased implementation plan for Paid. Each phase builds on the previous, delivering usable functionality at each step while progressing toward the complete vision.

**Current Status**: Phase 1 (Foundation) is complete as of 2026-02-08. Phase 2 (Intelligence) is next.

## Phase Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PAID IMPLEMENTATION PHASES                         │
│                                                                              │
│  Phase 1: Foundation✓   Phase 2: Intelligence   Phase 3: Scale              │
│  ──────────────────     ─────────────────────   ─────────────               │
│  • Rails app skeleton   • Prompt versioning     • Multi-agent               │
│  • GitHub integration   • A/B testing           • Auto-scaling              │
│  • Single agent         • Model meta-agent      • Quality gates             │
│  • Temporal setup       • Quality metrics       • Prompt evolution          │
│  • Container isolation  • Cost tracking         • Performance               │
│  • Manual PR creation   • Live dashboard        • Multi-tenancy prep        │
│                                                                              │
│  Phase 4: AI-Native Evolution                                               │
│  ────────────────────────────                                               │
│  • Learned orchestration strategies    • End-to-end optimization            │
│  • Self-improving coordination         • Orchestration scaling laws         │
│  • Decision logging & analysis         • Dynamic resource allocation        │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────► │
│  MVP: "It works"    Growth: "It learns"    Scale: "It flies"    "It evolves"│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Foundation

**Goal**: A working system where a user can add a GitHub project, label an issue, and have an agent open a PR.

### 1.1 Rails Application Skeleton

**Objective**: Basic Rails 8 app with authentication and core models.

**Status**: Complete (Issues #4, #6, #7, #8, #9, #10)

Tasks:

- [x] Initialize Rails 8 app with PostgreSQL
- [x] Set up Hotwire (Turbo + Stimulus) - included by default in Rails 8
- [x] Add authentication with Devise
- [x] Create core models: Account, User, Project, AgentRun
- [x] Basic UI: Projects list, add project form
- [x] Docker Compose for development (Rails + PostgreSQL, no Redis)
- [x] Set up RSpec, FactoryBot, and testing infrastructure (#6)
- [x] Set up GitHub Actions CI with coverage enforcement (#7)
- [x] Set up RuboCop and lint CI workflow (#8)
- [x] Set up Rolify and Pundit for authorization (#10) — later replaced with explicit AccountMembership/ProjectMembership tables per RDR-010

Deliverables:

- User can sign up/login
- User can see empty projects list
- Docker Compose brings up development environment

### 1.2 GitHub Integration

**Objective**: Connect to GitHub, fetch repo metadata, store PAT securely.

**Status**: Complete (Issues #11, #12, #13, #15, #16, #17)

Tasks:

- [x] Create GithubToken model (encrypted storage) (#11)
- [x] Add token setup UI with permission guidance (#16)
- [x] Implement GitHub API client (Octokit) (#15)
- [x] Fetch and display repository metadata (#15)
- [x] Create Project model linked to GitHub repo (#12)
- [x] Create Issue model for tracking GitHub issues (#13)
- [ ] Handle Projects V2 gracefully (feature detection) — deferred

Deliverables:

- User can add GitHub PAT with guided setup
- User can add projects (GitHub repos)
- Project shows repo metadata (name, description, last commit)
- System detects if Projects V2 is available

### 1.3 Temporal Integration (Basic)

**Objective**: Temporal server running, basic workflow execution working.

**Status**: Complete (Issues #18, #19, #20, #21)

Tasks:

- [x] Add Temporal to docker-compose (#18)
- [x] Integrate temporalio-ruby gem (#19)
- [x] Create Temporal client configuration (#19)
- [x] Implement first workflow: GitHubPollWorkflow (#20)
- [x] Implement first activity: FetchIssuesActivity (#20)
- [x] Set up fixed worker pool (single worker initially)
- [x] Basic workflow monitoring in UI (#21)

Deliverables:

- Temporal UI accessible at localhost:8080
- GitHubPollWorkflow runs on schedule
- Worker executes activities
- UI shows workflow status

### 1.4 Container Infrastructure

**Objective**: Agents run in isolated Docker containers.

**Status**: Complete (Issues #22, #23, #24, #25, #26)

Tasks:

- [x] Create base agent container image (#22)
- [x] Install agent CLIs supported by agent-harness (#22)
- [x] Implement container provisioning service (#23) — `Containers::Provision`
- [x] Set up git worktree management (#24) — `WorktreeService`, `Containers::GitOperations`
- [x] Implement network allowlist (firewall) (#25) — `NetworkPolicy`
- [x] Create secrets proxy service (#26) — `Api::SecretsProxyController`, `Api::GitCredentialsController`

Deliverables:

- Container image builds successfully
- Container can be provisioned for a project
- Worktree isolation works
- Agent CLI runs in container (manual test)

### 1.5 Single Agent Execution

**Objective**: End-to-end flow from labeled issue to PR.

**Status**: Complete (Issues #27, #28, #29, #30)

Tasks:

- [x] Implement label detection in GitHubPollWorkflow — `DetectLabelsActivity`
- [x] Create AgentExecutionWorkflow (#28)
- [x] Implement RunAgentActivity (single agent: Claude Code) (#27)
- [x] Capture agent output and logs — `AgentRunLog` model
- [x] Create PR via GitHub API (#29) — `CreatePullRequestActivity`
- [x] Update issue with PR link (#29) — `UpdateIssueWithPrActivity`
- [x] Basic error handling and retries
- [x] Manual trigger option in UI (#30)

Deliverables:

- Label issue with `paid-build` → agent runs → PR created
- Agent output visible in Paid UI
- Errors logged and visible
- Manual trigger option in UI

### 1.6 agent-harness Gem (Extracted)

**Objective**: Integrate the extracted agent CLI abstraction via the agent-harness gem.

**Status**: Complete (Issue #27)

Tasks:

- [x] Adopt the extracted agent-harness gem and wire it into Paid (#27) — `AgentRuns::Execute` service
- [x] Align provider registry with installed CLIs — `config/initializers/agent_harness.rb`
- [x] Use agent-harness orchestration hooks (provider switching, rate limits, health checks)
- [x] Map agent-harness token tracking into Paid cost tracking — `TokenUsageTracker`
- [ ] Publish gem (private initially) — deferred

Deliverables:

- `agent-harness` gem installable
- Consistent interface across all supported agents
- Orchestration signals available (rate limits, health, errors, tokens)
- Easy to add new agent types

### Phase 1 Completion Criteria

- [x] User can add a GitHub project with PAT
- [x] Accounts exist and scope users/projects (Devise-backed auth)
- [x] User can manually trigger an agent on an issue
- [x] Agent runs in isolated container
- [x] PR is created with agent's changes
- [x] Basic UI shows project status and agent runs
- [x] Temporal workflows are observable

**Phase 1 completed**: End-to-end MVP verified (Issue #31, closed 2026-02-08)

---

## Phase 2: Intelligence

**Goal**: The system learns from its performance and makes intelligent decisions about models and prompts.

### 2.1 Prompt Versioning System

**Objective**: All prompts are data with full version history.

Tasks:

- [ ] Create Prompt model with versioning
- [ ] Store prompts as structured data (template + variables)
- [ ] Create PromptVersion model (immutable)
- [ ] UI for viewing/editing prompts
- [ ] Prompt inheritance (global → project-specific)
- [ ] Prompt categories (planning, coding, review, etc.)

Deliverables:

- All agent prompts stored in database
- Full history of prompt changes
- UI to browse and edit prompts
- Prompts can be customized per project

### 2.2 Style Guide Management

**Objective**: LLM-friendly style guides, global and per-project.

Tasks:

- [ ] Create StyleGuide model
- [ ] Implement style guide compression (from aidp concepts)
- [ ] UI for editing style guides
- [ ] Automatic style guide extraction from codebase
- [ ] Style guide injection into prompts
- [ ] Tree-sitter integration for code analysis

Deliverables:

- Global style guide configurable
- Per-project style guide overrides
- Style guides automatically compressed for LLM context
- Code analysis informs style guide suggestions

### 2.3 Model Registry & Meta-Agent

**Objective**: Intelligent model selection based on task and budget.

Tasks:

- [ ] Integrate ruby-llm model registry
- [ ] Create ModelCapability tracking
- [ ] Implement meta-agent for model selection
- [ ] Rules-based fallback when meta-agent fails
- [ ] Model selection logging and analysis
- [ ] Per-project model preferences/restrictions

Deliverables:

- Model registry auto-updates from ruby-llm
- Meta-agent chooses model for each task
- Selection rationale logged
- Users can restrict models per project

### 2.4 Cost Tracking

**Objective**: Know exactly what each project costs.

Tasks:

- [ ] Create TokenUsage model
- [ ] Track usage per request (model, tokens, cost)
- [ ] Aggregate by project, time period
- [ ] Cost projection based on recent usage
- [ ] Budget alerts (warning thresholds)
- [ ] Cost dashboard in UI

Deliverables:

- Per-project cost visible in UI
- Historical cost trends
- Budget warning system
- Cost breakdown by model

### 2.5 A/B Testing Framework

**Objective**: Test prompt variants to find what works.

Tasks:

- [ ] Create ABTest model
- [ ] Implement test assignment logic
- [ ] Track metrics per variant
- [ ] Statistical significance calculation
- [ ] Auto-promotion of winners (optional)
- [ ] UI for creating and monitoring tests

Deliverables:

- Create A/B test for any prompt
- Automatic traffic splitting
- Metrics dashboard per test
- Clear winner identification

### 2.6 Quality Metrics & Feedback

**Objective**: Measure agent output quality automatically and via human feedback.

Tasks:

- [ ] Define quality metrics schema
- [ ] Implement automated metrics:
  - Iteration count to completion
  - CI pass rate
  - Code quality scores (linting, complexity)
  - PR merge rate
- [ ] Human feedback collection:
  - Thumbs up/down on PRs via GitHub
  - Webhook to receive feedback
- [ ] Quality dashboard

Deliverables:

- Automated quality scores per agent run
- Human feedback flows into Paid
- Quality trends visible over time
- Correlation between prompts and quality

### 2.7 Live Dashboard

**Objective**: Real-time visibility into agent activity.

Tasks:

- [ ] Action Cable setup for real-time updates
- [ ] Dashboard showing running workflows
- [ ] Agent activity stream (live logs)
- [ ] Interrupt/stop functionality
- [ ] Resource usage display (containers, workers)
- [ ] Alerts for anomalies

Deliverables:

- Real-time agent activity visible
- User can stop running agents
- Resource usage at a glance
- Alert notifications

### Phase 2 Completion Criteria

- [ ] All prompts versioned in database
- [ ] Style guides compress into LLM-friendly format
- [ ] Meta-agent selects models intelligently
- [ ] Costs tracked and displayed per project
- [ ] A/B tests runnable on prompts
- [ ] Quality metrics collected and displayed
- [ ] Live dashboard with interrupt capability

---

## Phase 3: Scale

**Goal**: Multiple agents work in parallel, prompts evolve automatically, and the system handles larger workloads.

### 3.1 Multi-Agent Orchestration

**Objective**: Multiple agents work on different parts of a feature simultaneously.

Tasks:

- [ ] Implement PlanningWorkflow for feature decomposition
- [ ] Create sub-issues in GitHub Projects
- [ ] Parallel AgentExecutionWorkflow invocation
- [ ] Coordination between related agents
- [ ] Conflict detection and resolution
- [ ] Aggregated PR creation option

Deliverables:

- Feature request decomposes into sub-tasks
- Multiple agents run in parallel
- No conflicts between agents' work
- Progress visible in GitHub Projects

### 3.2 Agent Monitoring & Guardrails

**Objective**: Prevent runaway agents and control costs.

Tasks:

- [ ] Implement infinite loop detection
- [ ] Token usage limits per run
- [ ] Cost limits per project (hard stop)
- [ ] Execution time limits
- [ ] Anomaly detection (unusual patterns)
- [ ] Automatic pause and alert

Deliverables:

- Agents automatically stopped when limits hit
- Alerts for anomalous behavior
- No surprise costs
- Visibility into why agent was stopped

### 3.3 Prompt Evolution

**Objective**: Prompts automatically improve based on performance.

Tasks:

- [ ] Implement PromptEvolutionWorkflow
- [ ] Random sampling of completed runs
- [ ] Prompt mutation agent
- [ ] Fitness function (quality + cost + speed)
- [ ] Evolutionary selection of prompts
- [ ] Human review of evolved prompts (optional gate)

Deliverables:

- Prompts evolve without manual intervention
- Evolution history trackable
- Quality improves over time (measurable)
- Human can review before promotion

### 3.4 Quality Gates

**Objective**: Automatically pause work when quality drops.

Tasks:

- [ ] Define quality thresholds (configurable)
- [ ] Implement quality gate checks in workflows
- [ ] Automatic pause on threshold breach
- [ ] Alert to user for intervention
- [ ] Quality recovery workflows
- [ ] Quality trend analysis

Deliverables:

- Workflows pause when quality drops
- User alerted with context
- Clear path to resume
- Quality tracked over time

### 3.5 Performance Optimization

**Objective**: Handle more projects and agents efficiently.

Tasks:

- [ ] Container pool warming
- [ ] Workflow batching optimizations
- [ ] Database query optimization
- [ ] Caching layer for GitHub data
- [ ] Worker pool tuning
- [ ] Performance benchmarking

Deliverables:

- Faster container startup
- Higher throughput
- Clear performance metrics
- Tuning recommendations

### 3.6 Auto-Scaling Preparation

**Objective**: Lay groundwork for automatic worker scaling.

Tasks:

- [ ] Worker metrics export
- [ ] Queue depth monitoring
- [ ] Scaling algorithm design
- [ ] Integration points for orchestrators (K8s, etc.)
- [ ] Documentation for scaling

Deliverables:

- Metrics available for scaling decisions
- Clear scaling recommendations
- Ready for auto-scaling implementation

### 3.7 Multi-Tenancy Preparation

**Objective**: Architecture ready for multiple teams/organizations.

Tasks:

- [ ] Tenant model design
- [ ] Data isolation patterns (schema or RLS)
- [ ] Per-tenant configuration
- [ ] Billing aggregation design
- [ ] Tenant onboarding flow design

Deliverables:

- Clear multi-tenancy architecture
- Data isolation strategy documented
- Migration path defined
- No breaking changes required

### Phase 3 Completion Criteria

- [ ] Multiple agents run in parallel on one feature
- [ ] Guardrails prevent runaway costs
- [ ] Prompts evolve based on measured performance
- [ ] Quality gates pause work automatically
- [ ] Performance handles 10+ concurrent projects
- [ ] Multi-tenancy migration path clear

---

## Phase 4: AI-Native Evolution

**Goal**: The system learns and improves its own orchestration through data, applying the Bitter Lesson to agent coordination itself.

This phase represents Paid's evolution from a well-engineered orchestration platform to a genuinely self-improving system. The core insight: if general methods that leverage computation beat hand-crafted approaches for LLMs, the same may be true for LLM orchestration.

### 4.1 Orchestration Decision Logging

**Objective**: Capture all orchestration decisions with full context for later learning.

Tasks:

- [ ] Create `orchestration_decisions` table
- [ ] Instrument workflows to log decomposition decisions
- [ ] Log agent selection decisions with context
- [ ] Log retry and escalation decisions
- [ ] Build analysis queries for decision patterns
- [ ] Dashboard showing orchestration metrics by context

Deliverables:

- 100% of orchestration decisions logged with context
- Analysis dashboard for decision patterns
- Foundation for all Phase 4 learning systems

Related: [RDR-014](rdrs/RDR-014-learned-orchestration.md)

### 4.2 Learned Orchestration Strategies

**Objective**: Orchestration strategies stored as data and evolved based on outcomes.

Tasks:

- [ ] Create `strategies` and `strategy_versions` tables
- [ ] Extract current hardcoded workflows into database strategies
- [ ] Implement context-aware strategy selection
- [ ] Create strategy evolution workflow (LLM-based mutation)
- [ ] A/B test evolved strategies against baseline
- [ ] Human review gate for strategy changes

Deliverables:

- Orchestration strategies as database entities
- Context-based strategy selection working
- First evolved strategy promoted via A/B test

Related: [RDR-014](rdrs/RDR-014-learned-orchestration.md)

### 4.3 End-to-End Outcome Optimization

**Objective**: Optimize entire configuration bundles (prompts + models + strategies) based on final outcomes.

Tasks:

- [ ] Create `configuration_bundles` and `bundle_outcomes` tables
- [ ] Implement configuration bundle tracking per agent run
- [ ] Build surrogate model (Random Forest initially, GP later)
- [ ] Implement Bayesian optimization for bundle selection
- [ ] Exploration/exploitation balance with context awareness
- [ ] Dashboard for bundle performance analysis

Deliverables:

- Configuration bundles versioned and tracked
- Bayesian optimizer selecting bundles for new tasks
- Measurable improvement in outcome/cost ratio

Related: [RDR-015](rdrs/RDR-015-end-to-end-optimization.md)

### 4.4 Self-Improving Agent Coordination

**Objective**: Coordination policies (decomposition, assignment, retry, escalation) evolve from outcomes.

Tasks:

- [ ] Create coordination policy data model
- [ ] Implement `DecompositionService` with policy-based rules
- [ ] Implement `FailureRecoveryService` with learned failure classification
- [ ] Implement `EscalationService` with human-value prediction
- [ ] Create policy evolution workflow
- [ ] A/B test evolved policies

Deliverables:

- All coordination decisions driven by evolvable policies
- Failure classification improves from data
- Escalation predictions validated against actual human value

Related: [RDR-016](rdrs/RDR-016-self-improving-coordination.md)

### 4.5 Orchestration Scaling Laws

**Objective**: Discover and apply scaling laws for agent orchestration.

Tasks:

- [ ] Create scaling observation instrumentation
- [ ] Design controlled experiments for scaling dimensions
- [ ] Run agent count scaling experiment
- [ ] Run iteration count scaling experiment
- [ ] Analyze parallelism effects
- [ ] Implement scaling-based resource allocator

Deliverables:

- Scaling exponents estimated for key dimensions
- Diminishing returns thresholds identified
- Dynamic allocation improves efficiency by 10%+

Related: [RDR-017](rdrs/RDR-017-orchestration-scaling-laws.md)

### Phase 4 Completion Criteria

- [ ] All orchestration decisions logged and analyzable
- [ ] At least one orchestration strategy evolved and promoted via A/B test
- [ ] End-to-end optimization shows measurable improvement
- [ ] Coordination policies adapt based on measured outcomes
- [ ] Scaling laws documented with confidence intervals
- [ ] System demonstrably improves with more data/compute

---

## Future Considerations (Beyond Phase 4)

These are not committed but worth keeping in mind:

### GitHub App Migration

- Move from PAT to GitHub App for better security and org support
- App marketplace listing

### Additional Integrations

- GitLab support
- Bitbucket support
- Jira integration
- Linear integration

### Advanced Agent Capabilities

- Agent collaboration (agents reviewing each other's work)
- Specialized agents (security review, performance optimization)
- Custom agent development framework

### Enterprise Features

- SSO/SAML authentication
- Audit logging
- Compliance reports
- On-premise deployment guide

### AI Capabilities

- Natural language project setup ("Add my Rails project and watch for bugs")
- Conversational interface for feature requests
- Predictive cost estimation

---

## Dependencies Between Phases

```
Phase 1.1 (Rails) ─────────────────────────────────────────────────►
          │
          ├── 1.2 (GitHub) ───────────────────────────────────────►
          │         │
          │         └── 2.2 (Style Guides) ──────────────────────►
          │
          ├── 1.3 (Temporal) ─────────────────────────────────────►
          │         │
          │         ├── 1.5 (Single Agent) ──────────────────────►
          │         │         │
          │         │         └── 3.1 (Multi-Agent) ────────────►
          │         │                   │
          │         │                   └── 4.1 (Decision Logging) ──►
          │         │                             │
          │         │                             ├── 4.2 (Learned Orchestration)
          │         │                             ├── 4.4 (Self-Improving Coord)
          │         │                             └── 4.5 (Scaling Laws)
          │         │
          │         └── 2.7 (Live Dashboard) ───────────────────►
          │
          └── 1.4 (Containers) ──────────────────────────────────►
                    │
                    └── 3.2 (Guardrails) ───────────────────────►

Phase 2.1 (Prompts) ─────────────────────────────────────────────►
          │
          ├── 2.5 (A/B Testing) ─────────────────────────────────►
          │         │
          │         ├── 3.3 (Prompt Evolution) ─────────────────►
          │         │
          │         └── 4.3 (End-to-End Optimization) ──────────►
          │
          └── 2.6 (Quality Metrics) ─────────────────────────────►
                    │
                    └── 3.4 (Quality Gates) ────────────────────►

Phase 2.3 (Model Meta-Agent) ────────────────────────────────────►
Phase 2.4 (Cost Tracking) ───────────────────────────────────────►
```

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Temporal complexity | Start simple, single workflow, add complexity gradually |
| Container overhead | Profile early, consider pool warming |
| Agent CLI instability | Abstraction layer isolates changes |
| Cost overruns | Implement guardrails early in Phase 2 |
| Quality degradation | A/B testing before full prompt evolution |
| Scope creep | Strict phase gates, MVP mindset |

---

## Success Metrics by Phase

### Phase 1

- Time from labeled issue to PR < 10 minutes
- Agent success rate > 70% (PR created)
- Zero secrets exposed

### Phase 2

- Model selection improves cost efficiency by 20%
- A/B tests identify winning prompts
- Quality metrics correlate with human feedback
- Dashboard latency < 1 second

### Phase 3

- 5+ agents running in parallel
- Prompt evolution shows measurable improvement
- Quality gates catch 90% of regressions
- Performance handles 10 concurrent projects

### Phase 4

- 100% of orchestration decisions logged and analyzable
- Learned orchestration strategies outperform hand-designed by 10%+
- End-to-end optimization improves outcome/cost ratio by 15%+
- Scaling laws estimated with 95% confidence intervals
- System shows measurable improvement month-over-month from learning

---

## Getting Started

1. Clone this repository
2. Review [ARCHITECTURE.md](./ARCHITECTURE.md) for system design
3. Review [DATA_MODEL.md](./DATA_MODEL.md) for schema design
4. Start with Phase 1.1: Rails Application Skeleton
5. Use the task lists above as implementation checklists

Each phase builds on the last. Don't skip ahead—the foundation matters.
