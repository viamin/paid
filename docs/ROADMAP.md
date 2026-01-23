# Paid Roadmap

This document outlines the phased implementation plan for Paid. Each phase builds on the previous, delivering usable functionality at each step while progressing toward the complete vision.

## Phase Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PAID IMPLEMENTATION PHASES                         │
│                                                                              │
│  Phase 1: Foundation          Phase 2: Intelligence       Phase 3: Scale    │
│  ──────────────────────       ───────────────────────     ───────────────   │
│  • Rails app skeleton         • Prompt versioning         • Multi-agent     │
│  • GitHub integration         • A/B testing framework     • Auto-scaling    │
│  • Single agent execution     • Model meta-agent          • Quality gates   │
│  • Basic Temporal setup       • Quality metrics           • Prompt evolution│
│  • Container isolation        • Cost tracking             • Performance     │
│  • Manual PR creation         • Live dashboard            • Multi-tenancy   │
│                                                             preparation     │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────► │
│  MVP: "It works"              Growth: "It learns"         Scale: "It flies" │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Foundation

**Goal**: A working system where a user can add a GitHub project, label an issue, and have an agent open a PR.

### 1.1 Rails Application Skeleton

**Objective**: Basic Rails 8 app with authentication and core models.

Tasks:
- [ ] Initialize Rails 8 app with PostgreSQL
- [ ] Set up Hotwire (Turbo + Stimulus)
- [ ] Add authentication (Devise or Rails 8 built-in)
- [ ] Create core models: User, Project, AgentRun
- [ ] Basic UI: Projects list, add project form
- [ ] Docker Compose for development (Rails + PostgreSQL + Redis)

Deliverables:
- User can sign up/login
- User can see empty projects list
- Docker Compose brings up development environment

### 1.2 GitHub Integration

**Objective**: Connect to GitHub, fetch repo metadata, store PAT securely.

Tasks:
- [ ] Create GithubToken model (encrypted storage)
- [ ] Add token setup UI with permission guidance
- [ ] Implement GitHub API client (Octokit)
- [ ] Fetch and display repository metadata
- [ ] Create Project model linked to GitHub repo
- [ ] Handle Projects V2 gracefully (feature detection)

Deliverables:
- User can add GitHub PAT with guided setup
- User can add projects (GitHub repos)
- Project shows repo metadata (name, description, last commit)
- System detects if Projects V2 is available

### 1.3 Temporal Integration (Basic)

**Objective**: Temporal server running, basic workflow execution working.

Tasks:
- [ ] Add Temporal to docker-compose (based on aidp's setup)
- [ ] Integrate temporalio-ruby gem
- [ ] Create Temporal client configuration
- [ ] Implement first workflow: GitHubPollWorkflow (skeleton)
- [ ] Implement first activity: FetchIssuesActivity
- [ ] Set up fixed worker pool (single worker initially)
- [ ] Basic workflow monitoring in UI

Deliverables:
- Temporal UI accessible at localhost:8080
- GitHubPollWorkflow runs on schedule
- Worker executes activities
- UI shows workflow status

### 1.4 Container Infrastructure

**Objective**: Agents run in isolated Docker containers.

Tasks:
- [ ] Create base agent container image (from aidp devcontainer)
- [ ] Install agent CLIs: Claude Code, Cursor, Codex, Copilot
- [ ] Implement container provisioning service
- [ ] Set up git worktree management
- [ ] Implement network allowlist (firewall)
- [ ] Create secrets proxy service (basic)

Deliverables:
- Container image builds successfully
- Container can be provisioned for a project
- Worktree isolation works
- Agent CLI runs in container (manual test)

### 1.5 Single Agent Execution

**Objective**: End-to-end flow from labeled issue to PR.

Tasks:
- [ ] Implement label detection in GitHubPollWorkflow
- [ ] Create AgentExecutionWorkflow
- [ ] Implement RunAgentActivity (single agent: Claude Code)
- [ ] Capture agent output and logs
- [ ] Create PR via GitHub API
- [ ] Update issue with PR link
- [ ] Basic error handling and retries

Deliverables:
- Label issue with `paid-build` → agent runs → PR created
- Agent output visible in Paid UI
- Errors logged and visible
- Manual trigger option in UI

### 1.6 agent-harness Gem (Extracted)

**Objective**: Extract agent CLI integration into reusable gem.

Tasks:
- [ ] Create agent-harness gem structure
- [ ] Extract provider abstraction from aidp concepts
- [ ] Implement adapters: ClaudeCode, Cursor, Codex, Copilot
- [ ] Unified interface for running agents
- [ ] Output parsing and structured results
- [ ] Publish gem (private initially)

Deliverables:
- `agent-harness` gem installable
- Consistent interface across all supported agents
- Easy to add new agent types

### Phase 1 Completion Criteria

- [ ] User can add a GitHub project with PAT
- [ ] User can manually trigger an agent on an issue
- [ ] Agent runs in isolated container
- [ ] PR is created with agent's changes
- [ ] Basic UI shows project status and agent runs
- [ ] Temporal workflows are observable

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

## Future Considerations (Beyond Phase 3)

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
          │         └── 3.3 (Prompt Evolution) ─────────────────►
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

---

## Getting Started

1. Clone this repository
2. Review [ARCHITECTURE.md](./ARCHITECTURE.md) for system design
3. Review [DATA_MODEL.md](./DATA_MODEL.md) for schema design
4. Start with Phase 1.1: Rails Application Skeleton
5. Use the task lists above as implementation checklists

Each phase builds on the last. Don't skip ahead—the foundation matters.
