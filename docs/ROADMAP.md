# Paid Roadmap

This document outlines the phased implementation plan for Paid. Each phase builds on the previous, delivering usable functionality at each step while progressing toward the complete vision.

**Current Status**: Phase 3 (Scale) complete as of 2026-05-07. Phase 3.5 (Completion & Hardening) substantially complete as of 2026-05-07 with one remaining Runner Quota Tracking Step 1 task. Phase 4 (AI-Native Evolution) complete as of 2026-05-14. Remote container execution (RDR-019) completed as of 2026-05-16. Phase 5 (Account Administration) is next.

## Phase Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PAID IMPLEMENTATION PHASES                         │
│                                                                              │
│  Phase 1: Foundation✓   Phase 2: Intelligence✓  Phase 3: Scale✓              │
│  ──────────────────     ──────────────────────  ─────────────               │
│  • Rails app skeleton   • Prompt versioning     • Multi-agent               │
│  • GitHub integration   • A/B testing           • Auto-scaling              │
│  • Single agent         • Model meta-agent      • Quality gates             │
│  • Temporal setup       • Quality metrics       • Prompt evolution          │
│  • Container isolation  • Cost tracking         • Performance               │
│  • Manual PR creation   • Semantic code search  • Multi-tenancy prep        │
│  •                      • Live dashboard        •                           │
│                                                                              │
│  Phase 3.5: Completion & Hardening                                          │
│  ─────────────────────────────────                                           │
│  • Security & reliability P1s     • Performance fundamentals (partial)      │
│  • Wire half-built Phase 2 feats  • Quality recovery workflows              │
│  • Multi-runner & model select   • Fair queueing                            │
│  • MCP server support             • Screenshot visual regression            │
│  • Self-healing exception handling • Knowledge provider resilience          │
│  • Agent run enhancements         • Notification subscriptions              │
│                                                                              │
│  Phase 4: AI-Native Evolution                                               │
│  ────────────────────────────                                               │
│  • Learned orchestration strategies    • End-to-end optimization            │
│  • Self-improving coordination         • Orchestration scaling laws         │
│  • Decision logging & analysis         • Dynamic resource allocation        │
│                                                                              │
│  Phase 5: Account Administration                                            │
│  ───────────────────────────────                                            │
│  • Avo operator console              • User-facing account admin            │
│  • Tenant lifecycle operations       • Team, roles, settings, billing       │
│                                                                              │
│  Phase 6: Enterprise Trust & Governance                                     │
│  ─────────────────────────────────────                                      │
│  • GitHub App & enterprise auth       • Audit logs and policy controls      │
│  • Compliance and approval workflows  • Security governance                 │
│                                                                              │
│  Phase 7: Proof, Adoption & Interop                                         │
│  ───────────────────────────────────                                         │
│  • ROI/evals against alternatives     • Migration and coexistence paths     │
│  • Benchmarking and executive proof   • Change management                   │
│                                                                              │
│  Phase 8: Managed Platform & Ecosystem                                      │
│  ────────────────────────────────────                                       │
│  • Managed cloud / private SaaS       • Enterprise operations               │
│  • Marketplace and ecosystem          • Customer deployment models          │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────► │
│  MVP: "It works"   Growth: "It learns"   Scale: "It flies"   "It operates" │
│  Trust: "It governs"   Proof: "It wins"   Platform: "It scales to market"  │
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

**Status**: Complete as of 2026-04-01.

### 2.1 Prompt Versioning System

**Objective**: All prompts are data with full version history.

**Status**: Complete — `Prompt` and `PromptVersion` models with full CRUD UI, global → account → project inheritance, and planning/coding/review/testing categories.

Tasks:

- [x] Create Prompt model with versioning — `Prompt`, `PromptVersion` models
- [x] Store prompts as structured data (template + variables)
- [x] Create PromptVersion model (immutable)
- [x] UI for viewing/editing prompts — `PromptsController` with diff endpoint
- [x] Prompt inheritance (global → account → project-specific)
- [x] Prompt categories (planning, coding, review, testing)

Deliverables:

- All agent prompts stored in database
- Full history of prompt changes
- UI to browse and edit prompts
- Prompts can be customized per project

### 2.2 Style Guide Management

**Objective**: LLM-friendly style guides, global and per-project.

**Status**: Complete — `StyleGuide` model with language-specific support, LLM-based compression, automatic extraction, and tree-sitter AST parsing.

Tasks:

- [x] Create StyleGuide model — language-specific (Ruby, JS, TS, Python, Go, Rust)
- [x] Implement style guide compression — `StyleGuides::Compress` (LLM-based)
- [x] UI for editing style guides — `StyleGuidesController` with compress/extract actions
- [x] Automatic style guide extraction from codebase — `StyleGuides::Extract`, `StyleGuideExtractionJob`
- [x] Style guide injection into prompts — `StyleGuides::InjectIntoPrompt`
- [x] Tree-sitter integration for code analysis — `Knowledge::Collectors::TreeSitterCollector`

Deliverables:

- Global style guide configurable
- Per-project style guide overrides
- Style guides automatically compressed for LLM context
- Code analysis informs style guide suggestions

### 2.3 Model Registry & Meta-Agent

**Objective**: Intelligent model selection based on task and budget.

**Status**: Complete — `LlmModel` catalog with capability scoring, `Models::MetaAgentSelector` and `Models::RulesBasedSelector`, selection logged via `ModelSelection`.

Tasks:

- [x] Integrate ruby-llm model registry — `LlmModel` with categories and capability scores
- [x] Create ModelCapability tracking — scoring 0-10 per model, cost per million tokens
- [x] Implement meta-agent for model selection — `Models::MetaAgentSelector`
- [x] Rules-based fallback when meta-agent fails — `Models::RulesBasedSelector`
- [x] Model selection logging and analysis — `ModelSelection` model
- [x] Per-project model preferences/restrictions — `Runner` model with project scoping and fallback roles

Deliverables:

- Model registry auto-updates from ruby-llm
- Meta-agent chooses model for each task
- Selection rationale logged
- Users can restrict models per project

### 2.4 Cost Tracking

**Objective**: Know exactly what each project costs.

**Status**: Complete — `TokenUsage` model with per-request tracking, `CostBudget` with alert thresholds, and per-project cost dashboards.

Tasks:

- [x] Create TokenUsage model
- [x] Track usage per request (model, tokens, cost) — `TokenUsageTracker`
- [x] Aggregate by project, time period — `TokenUsages::Aggregate`
- [x] Cost projection based on recent usage
- [x] Budget alerts (warning thresholds) — `CostBudget` model, `CostBudgets::Check`
- [x] Cost dashboard in UI — `CostDashboardsController`

Deliverables:

- Per-project cost visible in UI
- Historical cost trends
- Budget warning system
- Cost breakdown by model

### 2.5 A/B Testing Framework

**Objective**: Test prompt variants to find what works.

**Status**: Complete — `AbTest` model with full lifecycle (draft/running/completed/cancelled), statistical analysis, auto-promotion, and UI.

Tasks:

- [x] Create AbTest model — `AbTest`, `AbTestVariant`, `AbTestAssignment`
- [x] Implement test assignment logic — `AbTests::Assign`
- [x] Track metrics per variant — `AbTests::RecordResult`
- [x] Statistical significance calculation — `AbTests::Statistics`, `AbTests::Analyze`
- [x] Auto-promotion of winners (optional) — `AbTests::PromoteWinner`
- [x] UI for creating and monitoring tests — `AbTestsController` with start/cancel/promote

Deliverables:

- Create A/B test for any prompt
- Automatic traffic splitting
- Metrics dashboard per test
- Clear winner identification

### 2.6 Quality Metrics & Feedback

**Objective**: Measure agent output quality automatically and via human feedback.

**Status**: Complete — `QualityMetric` model with automated and human feedback collection, composite scoring by goal type, trend analysis, and dashboards.

Tasks:

- [x] Define quality metrics schema — `QualityMetric` with goal-specific composite weights
- [x] Implement automated metrics — `QualityMetrics::CollectAutomated`
  - Iteration count to completion
  - CI pass rate
  - Code quality scores (linting, complexity)
  - PR merge rate
- [x] Human feedback collection — `CollectReviewFeedback`, `CollectReactionFeedback`, `CollectCommentFeedback`, `CollectIssueFeedback`
  - Thumbs up/down on PRs via GitHub
  - Webhook to receive feedback — `Api::GithubWebhooksController`
- [x] Quality dashboard — `QualityDashboardsController` (system-wide and per-project)

Deliverables:

- Automated quality scores per agent run
- Human feedback flows into Paid
- Quality trends visible over time
- Correlation between prompts and quality

### 2.7 Semantic Code Search

**Objective**: Agents have indexed codebase knowledge from their first run on a project.

**Status**: Complete — Full knowledge pipeline with 8+ collectors, Qdrant vector DB, hybrid search (exact + semantic + reranked), staleness detection, redaction, and audit trail.

Tasks:

- [x] Add Qdrant to docker-compose — `QdrantClient`, `Knowledge::Qdrant::CollectionManager`
- [x] Create KnowledgeChunk model and Qdrant collection management — `KnowledgeArtifact`, `KnowledgeChunk`, `KnowledgeLink`
- [x] Implement indexing pipeline — 8 collectors (symbol index, tree-sitter, language stats, routes, config keys, dependencies, churn hotspots, ADRs)
- [x] Implement search service — `Knowledge::Search::Exact` (identifier/LIKE matching), `Knowledge::Search::Semantic` (Qdrant + tsvector FTS), `Knowledge::Search::Hybrid` (combined + reranking)
- [x] Trigger deep indexing on project creation — `EnqueueKnowledgeCollectionJob`
- [x] Incremental re-indexing — staleness detection via `Knowledge::Staleness::Detector`
- [x] Integrate semantic context into agent prompts — `Knowledge::ContextBundle::Build` → `Prompts::BuildForIssue`
- [x] UI for index status and manual re-indexing — knowledge search UI, settings, artifact viewer

Deliverables:

- New projects are deeply indexed on creation
- Agents receive relevant codebase context in their prompts
- Semantic search ("how does auth work?") and exact search ("def authenticate_user") both work
- Per-project isolation via separate Qdrant collections

Related (earlier MeiliSearch-based design): [RDR-018](rdrs/RDR-018-semantic-code-search.md)

### 2.8 Live Dashboard

**Objective**: Real-time visibility into agent activity.

**Status**: Complete — Action Cable broadcasting with live stats, agent run cancellation, container/service metrics, and real-time dashboard updates.

Tasks:

- [x] Action Cable setup for real-time updates — `Dashboard::Broadcaster`, `Dashboard::LiveBroadcaster`
- [x] Dashboard showing running workflows — `DashboardController`
- [x] Agent activity stream (live logs) — `AgentRunLog`, `AgentRunPhase` models
- [x] Interrupt/stop functionality — `AgentRuns::Cancel`, cancel action on runs
- [x] Resource usage display (containers, workers) — `ContainerMetric`, `ServiceContainerMetric`
- [x] Live stats — `Dashboard::LiveStats`, `LiveDashboardBroadcastJob`

Deliverables:

- Real-time agent activity visible
- User can stop running agents
- Resource usage at a glance
- Alert notifications

### Phase 2 Completion Criteria

- [x] All prompts versioned in database
- [x] Style guides compress into LLM-friendly format
- [x] Meta-agent selects models intelligently
- [x] Costs tracked and displayed per project
- [x] A/B tests runnable on prompts
- [x] Quality metrics collected and displayed
- [x] Projects indexed on creation with semantic + full-text search available to agents
- [x] Live dashboard with interrupt capability

**Phase 2 completed**: All intelligence features verified as of 2026-04-01.

---

## Phase 3: Scale

**Goal**: Multiple agents work in parallel, prompts evolve automatically, and the system handles larger workloads.

**Status**: Complete as of 2026-05-07. Tracked by umbrella issue #741.

### 3.1 Multi-Agent Orchestration

**Objective**: Multiple agents work on different parts of a feature simultaneously.

**Status**: Complete — `PlanningWorkflow` decomposes features into sub-tasks; `ParallelAgentExecutionWorkflow` runs multiple agents concurrently with capacity checks, batch execution, and deadline enforcement. Conflict detection/resolution and aggregated PR creation included.

Tasks:

- [x] Implement PlanningWorkflow for feature decomposition (#694)
- [x] Create sub-issues in GitHub from decomposed plan (#695)
- [x] Parallel AgentExecutionWorkflow invocation (#696)
- [x] Coordination between related agents (#697)
- [x] Conflict detection and resolution (#698)
- [x] Aggregated PR creation option (#699)

Deliverables:

- Feature request decomposes into sub-tasks
- Multiple agents run in parallel
- No conflicts between agents' work
- Progress visible in GitHub Projects

### 3.2 Agent Monitoring & Guardrails

**Objective**: Prevent runaway agents and control costs.

**Status**: Complete — `AgentRuns::DetectInfiniteLoop` detects repeated/cycling output; `CostBudget` enforces token and cost limits with `hard_stop` mode; `Anomalies::Detect` uses z-score baselines; `Guardrails::ViolationHandler` pauses runs on all five violation types (loop, token, cost, time, anomaly) and publishes dashboard alerts.

Tasks:

- [x] Implement infinite loop detection (#700)
- [x] Token usage limits per run (#701)
- [x] Cost limits per project (hard stop) (#702)
- [x] Execution time limits (#703)
- [x] Anomaly detection (unusual patterns) (#704)
- [x] Automatic pause and alert (#705)

Deliverables:

- Agents automatically stopped when limits hit
- Alerts for anomalous behavior
- No surprise costs
- Visibility into why agent was stopped

### 3.3 Prompt Evolution

**Objective**: Prompts automatically improve based on performance.

**Status**: Complete — `PromptEvolutionWorkflow` runs a weekly cycle: sample runs → generate LLM mutations → persist `PromptVersion` variants → create A/B test. `PromptReviewsController` provides human review gate. `PromptEvolution::Select` evaluates fitness.

Tasks:

- [x] Implement PromptEvolutionWorkflow (#706)
- [x] Random sampling of completed runs (#707)
- [x] Prompt mutation agent (#708)
- [x] Fitness function (quality + cost + speed) (#709)
- [x] Evolutionary selection of prompts (#710)
- [x] Human review of evolved prompts (optional gate) (#711)

Deliverables:

- Prompts evolve without manual intervention
- Evolution history trackable
- Quality improves over time (measurable)
- Human can review before promotion

### 3.4 Quality Gates

**Objective**: Automatically pause work when quality drops.

**Status**: Complete — `QualityGateThreshold` model with configurable per-project thresholds, `QualityAlerts::CheckGate` and `QualityPause::Check` enforce gates and auto-pause. `QualityMetrics::TrendAnalysis` integrated. Quality recovery workflows (#716) now fully implemented (see Phase 3.5.5).

Tasks:

- [x] Define quality thresholds (configurable) (#712)
- [x] Implement quality gate checks in workflows (#713)
- [x] Automatic pause on threshold breach (#714)
- [x] Alert to user for intervention (#715)
- [x] Quality recovery workflows (#716) — `QualityRecoveryAction` model, `QualityRecovery::ModelEscalation`, `AutoImprove`, `Diagnose`, `SuggestFixes`, `ResumeWithMonitoring`, `ExecuteAction`
- [x] Quality trend analysis with gate integration (#717)

Deliverables:

- Workflows pause when quality drops
- User alerted with context
- Clear path to resume
- Quality tracked over time

### 3.5 Performance Optimization

**Objective**: Handle more projects and agents efficiently.

**Status**: Complete — GitHub API caching layer (`Github::CacheService`, `CacheWarmer`, `CacheMetrics`, `CacheInvalidator`), container pool warming, database query optimization, workflow batching, worker pool tuning, and performance benchmarking all done.

Tasks:

- [x] Container pool warming (#718)
- [x] Workflow batching optimizations (#719)
- [x] Database query optimization (#720)
- [x] Caching layer for GitHub data (#721) — `Github::CacheService`, `CacheWarmer`, `CacheMetrics`, `CacheInvalidator`
- [x] Worker pool tuning (#722)
- [x] Performance benchmarking (#723)

Deliverables:

- Faster container startup
- Higher throughput
- Clear performance metrics
- Tuning recommendations

### 3.6 Auto-Scaling Preparation

**Objective**: Lay groundwork for automatic worker scaling.

**Status**: Complete — `Scaling::WorkerPoolAdvisor` implements hybrid reactive/predictive algorithm with cost caps and cooldown. `Scaling::QueueMonitor` + `QueueMonitorJob` track GoodJob, Temporal, and agent-run queues. `Scaling::Orchestrator` now exposes concrete adapters for Kubernetes, Docker Swarm, ECS, and Docker Compose. Remote container execution is also complete: `Containers::Provision` routes through backend abstractions with `LocalDocker`, `RemoteDocker`, and `Swarm` backends, `container_host` tracking persists backend placement, and operator guides live in `docs/guides/remote-docker-setup.md` and `docs/guides/swarm-setup.md`. Scaling documentation in `docs/SCALING.md`, `docs/runbooks/scaling.md`, `docs/rdrs/RDR-033`, and `docs/rdrs/RDR-019`.

Tasks:

- [x] Worker metrics export (#724)
- [x] Queue depth monitoring (#725)
- [x] Scaling algorithm design (#726)
- [x] Integration points for orchestrators (K8s, etc.) (#727)
- [x] Documentation for scaling (#728)
- [x] Remote container execution across local Docker, remote Docker, and Docker Swarm backends (#2029)

Deliverables:

- Metrics available for scaling decisions
- Clear scaling recommendations
- Ready for auto-scaling implementation
- Agent containers can run on local Docker, a single remote Docker host, or a Docker Swarm cluster

### 3.7 Multi-Tenancy Preparation

**Objective**: Architecture ready for multiple teams/organizations.

**Status**: Complete — `Account` model with plan tiers (trial/free/professional/enterprise), `TenantSetting` with resource limits, `TenantScoped` concern for application-level isolation. Billing schema designed (4 tables: plans, periods, invoices, line_items). Tenant onboarding flow designed.

Tasks:

- [x] Tenant model design (#729) — `Account` with plans, `TenantSetting` with limits, `TenantScoped` concern
- [x] Data isolation patterns (schema or RLS) (#730) — `TenantScoped` concern with `for_tenant` / `for_current_tenant` scopes
- [x] Per-tenant configuration (#731) — `TenantSetting` model with limits and feature flags
- [x] Billing aggregation design (#732) — schema tables for `billing_plans`, `billing_periods`, `billing_invoices`, `billing_line_items` (models pending)
- [x] Tenant onboarding flow design (#733)

Deliverables:

- Clear multi-tenancy architecture
- Data isolation strategy documented
- Migration path defined
- No breaking changes required

### Phase 3 Completion Criteria

- [x] Multiple agents run in parallel on one feature
- [x] Guardrails prevent runaway costs
- [x] Prompts evolve based on measured performance
- [x] Quality gates pause work automatically
- [x] Performance handles 10+ concurrent projects
- [x] Multi-tenancy migration path clear

**Phase 3 completed**: All scale features verified as of 2026-05-07.

---

## Phase 3.5: Completion & Hardening

**Goal**: Close gaps in Phase 2–3 feature completion, fix security and reliability P1s, and ensure the system is production-ready at scale before beginning Phase 4's learning systems.

**Why this phase exists**: Phase 3's core features are built (multi-agent orchestration, prompt evolution, guardrails, scaling infrastructure), but open issues reveal unfinished wiring in Phase 2's intelligence layer and several security/reliability gaps. Phase 4's learning systems require these foundations to be solid — A/B tests must produce real data, multi-runner must work end-to-end, and the system must handle concurrent load without credential leaks or data drift.

**Status**: Substantially complete. Section 3.5.4 (Performance Fundamentals) is complete. Section 3.5.6 (Runner Quota Tracking) Step 1 has one remaining task (`Add per-runner circuit breaker history`); Step 2 is complete; Steps 3–6 are deferred to Phase 4.

### 3.5.1 Security & Reliability

**Objective**: Fix P1 security vulnerabilities and data integrity issues.

**Status**: Complete — All P1 security and data integrity issues resolved.

Tasks:

- [x] Remove direct runner credential injection from agent runs (#1281)
- [x] Fix schema.rb drift from shared database across agent containers (#1280)
- [x] Fix container network isolation alignment across runner auth modes (#1284)
- [x] Fix GitHub sync incremental watermark permanently skipping issues (#1257)
- [x] Fix notification Turbo Frame mismatch ("Content missing") (#1263)

Deliverables:

- No credentials exposed to agent containers except through secrets proxy
- Schema.rb stays consistent across container runs
- GitHub issue sync is lossless
- Notifications navigate correctly

### 3.5.2 Core Feature Completion

**Objective**: Wire half-built Phase 2 features so they work end-to-end in production.

**Status**: Complete — All Phase 2 features now wired end-to-end in production.

Tasks:

- [x] Wire A/B test assignment into live agent execution (#1267)
- [x] Complete enhance_issue pipeline: knowledge context injection (#1265)
- [x] Complete enhance_issue pipeline: quality metrics (#1266)
- [x] Complete enhance_issue pipeline: label management and re-evaluation loop (#991)
- [x] Add tests for enhance_issue enhancement and re-evaluation workflow (#992)
- [x] Replace "primary runner" with "automated runner" and multi-runner modes (#778)
- [x] Intelligent model selection based on task complexity (#760)
- [x] Add container-authenticated knowledge search endpoint for agent tool access (#1272)

Deliverables:

- A/B tests produce real quality data from live agent runs
- enhance_issue goal works end-to-end with knowledge, quality, and re-evaluation
- Users can configure multiple runners with automatic selection and fallback
- Agents can search the knowledge base from within containers

### 3.5.3 Fair Queueing

**Objective**: Prevent any single user or project from monopolizing agent run capacity.

**Status**: Complete — Within-user round-robin and cross-user interleaving both implemented.

Tasks:

- [x] Implement within-user fair queueing across projects (#1274)
- [x] Implement cross-user fair queueing (#1275)

Deliverables:

- No single user can starve others of agent capacity
- Projects share capacity proportionally within a user's account
- Queue depth visible in dashboard

### 3.5.4 Performance Fundamentals

**Objective**: Complete the remaining Phase 3.5 performance items needed to handle 10+ concurrent projects.

**Status**: Complete — Performance benchmarking suite runs in CI with 5 benchmark types, database query optimizations (distinct_effective_runners cache, deferred cost snapshots, fasterer performance lint), container pool warming, workflow batching, worker pool tuning, and GitHub API call reduction all done.

Tasks:

- [x] Container pool warming (#718)
- [x] Database query optimization (#720) — distinct_effective_runners cache (#1586), deferred cost snapshots (#1580), fasterer performance lint (#1595)
- [x] Workflow batching optimizations (#719)
- [x] Worker pool tuning (#722)
- [x] Performance benchmarking suite (#723) — benchmark types, CI integration, baseline tracking, regression checking (#1559)
- [x] Reduce GitHub API calls per polling cycle (#879)

Deliverables:

- Faster container startup via pre-warmed pool
- Database queries optimized for multi-project concurrency
- Baseline performance benchmarks established
- Tuning recommendations documented

### 3.5.5 Quality Recovery

**Objective**: Complete the quality gate loop — when quality gates pause work, provide a clear path to resume.

**Status**: Complete — `QualityRecoveryAction` model with `QualityRecovery::ModelEscalation`, `AutoImprove`, `Diagnose`, `SuggestFixes`, `ResumeWithMonitoring`, and `ExecuteAction` services. Integrated into `QualityPause::Check`, `Models::Select`, and `CheckQualityGateActivity`.

Tasks:

- [x] Implement quality recovery workflows (#716) — `QualityRecoveryAction` model, `QualityRecovery::ModelEscalation`, `AutoImprove`, `Diagnose`, `SuggestFixes`, `ResumeWithMonitoring`, `ExecuteAction` services

Deliverables:

- Quality pause events trigger recovery suggestions
- Users can acknowledge and resume with actionable next steps

### 3.5.6 Runner Quota Tracking

**Objective**: Give users visibility into upstream provider subscription quotas and use that data to make smarter runner routing decisions.

**Why this matters**: Users with active subscriptions (Claude Pro, Codex Pro, Copilot Business, Z.ai Coding Max) need to know how close each runner is to hitting its quota, and Paid should proactively avoid routing to nearly-exhausted runners instead of waiting for 429 errors.

**RDR**: [RDR-025](rdrs/RDR-025-runner-quota-tracking.md)

**Approach**: Provider-specific quota API knowledge and response parsing live in agent-harness (per AGENTS.md boundary). Paid stores credentials, persists snapshots, displays data, and makes routing decisions. Starts with a quick win showing existing internal usage data, then layers on upstream quota polling.

#### Step 1: Internal Runner Usage Display (Quick Win)

Display per-runner aggregations from data Paid already collects — no new credentials or APIs needed.

Tasks:

- [x] Create `Runners::UsageStats` service — aggregate `TokenUsage` by `AgentRun.effective_runner` for 7-day and 30-day windows
- [x] Add per-runner spend column to `/runners` index (tokens, cost, run count)
- [x] Add per-runner fallback frequency display (from `runners_attempted` JSON)
- [x] Add per-runner rate-limit event count (from `AgentRun` statuses)
- [ ] Add per-runner circuit breaker history (recent transitions from `RunnerState`)

Deliverables:

- `/runners` page shows how much Paid has consumed from each runner
- Users can see which runners hit rate limits most often
- Zero new infrastructure required

#### Step 2: Upstream Provider-Specific Code to agent-harness

Move existing provider-specific logic from Paid into agent-harness where it belongs per AGENTS.md. This is tech debt payoff that also establishes the provider-class extension pattern needed for quota polling.

Tasks:

- [x] Move `AUTH_EXPIRED_PATTERNS` (Codex-specific) to agent-harness Codex provider class
- [x] Move `PROVIDER_ABORT_PATTERNS` to agent-harness provider classes
- [x] Deduplicate and move `parse_rate_limit_reset` to agent-harness provider classes
- [x] Move `api_key_env_var_names_for` / `api_key_unset_vars_for` / `SUBSCRIPTION_AUTH_UNSET_VARS` to agent-harness provider classes as `env_var_names` / `subscription_unset_vars`
- [x] Move Codex config TOML format (`wire_api`, `model_provider`) to agent-harness Codex provider class
- [x] Move Gemini-specific env vars (`GEMINI_SANDBOX`, `GEMINI_CLI_DISABLE_RETRIES`) to agent-harness Gemini provider class
- [x] Move Codex OAuth lockfile mechanism to agent-harness Codex provider class — config path upstreamed; flock-based locking remains in Paid (infrastructure concern)
- [x] Move provider-specific test command flags to agent-harness provider classes
- [x] Move secrets proxy token extraction (Anthropic/OpenAI/Google response shapes) to agent-harness provider classes
- [x] Move TestAgent error patterns to agent-harness provider classes
- [x] Replace all Paid hard-coded arrays/methods with agent-harness calls — remaining Paid-side arrays are proxy infrastructure, not provider execution knowledge

Deliverables:

- No provider-specific error patterns, env var names, or config formats hard-coded in Paid
- All provider-specific execution knowledge centralized in agent-harness
- agent-harness provider classes have the extension points needed for quota polling

#### Step 3: Quota Polling Interface in agent-harness

Add `provider_quota()` method to agent-harness with per-provider implementations. Start with Z.ai (simplest — API key auth), then expand to Claude, Codex, and Copilot.

Tasks:

- [ ] Design `QuotaSnapshot` and `QuotaMetric` data structures in agent-harness
- [ ] Add `supports_quota_polling?`, `quota(credentials:)`, `quota_credentials_type` to provider base class
- [ ] Implement Z.ai quota polling (`api.z.ai/api/monitor/usage/quota/limit`)
- [ ] Implement Claude quota polling (`api.anthropic.com/api/oauth/usage`) with OAuth refresh
- [ ] Implement Codex quota polling (`chatgpt.com/backend-api/wham/usage`) with OAuth refresh
- [ ] Implement Copilot quota polling (`api.github.com/copilot_internal/user`)
- [ ] Implement Cursor quota polling (`api2.cursor.sh/.../GetCurrentPeriodUsage`) with OAuth refresh
- [ ] Add `AgentHarness.all_provider_quotas` orchestration method

Deliverables:

- `AgentHarness.provider_quota(:zai, credentials: { api_key: "..." })` returns `QuotaSnapshot`
- Each provider knows its quota API, response format, and credential requirements
- Paid can call a single interface regardless of provider

#### Step 4: Quota Storage and Scheduled Refresh in Paid

Wire agent-harness quota polling into Paid with encrypted credential storage and scheduled refresh.

Tasks:

- [ ] Create `runner_quota_credentials` table (encrypted OAuth tokens/API keys per runner)
- [ ] Create `runner_quota_snapshots` table (cached quota metrics per runner)
- [ ] Create `RunnerQuotaCredential` model with encryption
- [ ] Create `RunnerQuotaSnapshot` model with upsert logic
- [ ] Create `Runners::RefreshQuotas` service (calls agent-harness, upserts snapshots)
- [ ] Create `Runners::RefreshQuotasJob` (GoodJob cron, every 15 minutes)
- [ ] Add credential collection UI for Z.ai (API key — reuses `ProviderApiKey` pattern)
- [ ] Add credential collection UI for Copilot (GitHub token)
- [ ] Add opportunistic OAuth token capture for Claude/Codex (read from container after successful run)
- [ ] Add quota display to `/runners` page (progress bars, plan name, reset timers)

Deliverables:

- Quota snapshots refresh on schedule for all configured runners
- `/runners` page shows real upstream quota status per runner
- Users can configure credentials for quota polling per runner

#### Step 5: Quota-Aware Runner Routing

Enhance runner selection to consider upstream quota state when choosing which runner to use for a run.

Tasks:

- [ ] Create `Runners::QuotaScore` service (scores runners by remaining quota)
- [ ] Enhance `RunAgentActivity#build_runner_order` to incorporate quota scores
- [ ] Add quota-based routing logging (visible in dashboard and run details)
- [ ] Add quota-exhaustion anticipation: prefer fallback when primary > 80% session usage

Deliverables:

- Runner routing considers upstream quota state, not just circuit breaker health
- Runs avoid runners nearing quota exhaustion
- Routing decisions logged with quota context

#### Step 6: Predictive Analytics (Future)

Use historical data to predict quota exhaustion and suggest configuration changes.

Tasks:

- [ ] Build quota consumption rate model from historical `RunnerQuotaSnapshot` data
- [ ] Add "predicted exhaustion" cards to dashboard ("Claude session will exhaust in ~2 hours")
- [ ] Add runner configuration suggestions ("Copilot at 92% — consider adding Codex fallback")
- [ ] Add weekly quota digest notification

Deliverables:

- Users receive proactive alerts before quotas exhaust
- System suggests optimal runner configuration

### Phase 3.5 Completion Criteria

- [x] Zero P1 security or data integrity issues open
- [x] A/B tests produce data from live agent runs
- [x] enhance_issue goal works end-to-end
- [x] Multi-runner with automatic selection works
- [x] Fair queueing prevents capacity starvation
- [x] Performance handles 10+ concurrent projects with benchmarks
- [x] Runner quota tracking: per-runner usage visible on /runners page
- [x] Provider-specific code upstreamed to agent-harness
- [x] ~~Upstream quota polling~~ — deferred to Phase 4
- [x] MCP server support for agent tool use and project configuration
- [x] Interactive chat with streaming UI, cost tracking, and container workspace
- [x] Self-healing exception handling with auto-issue filing
- [x] Screenshot visual regression for PRs with UI changes

**Phase 3.5 substantially complete**: All hardening work except `Add per-runner circuit breaker history` verified as of 2026-05-07.

### 3.5.7 Interactive Chat

**Objective**: Provide a conversational interface for users to interact with Paid's knowledge and agent capabilities in real time.

**RDR**: [RDR-028](rdrs/RDR-028-interactive-chat.md)

Tasks:

- [x] Create chat sessions and messages database schema (#1485) — `chat_sessions`, `chat_messages`, `chat_session_projects`
- [x] Create chat session service layer (#1514) — `ChatSessions::Create`, `SendMessage`, `Close`
- [x] Add chat system prompt and context injection (#1521) — `ChatSessions::BuildSystemPrompt`
- [x] Add chat API endpoints with SSE streaming (#1523) — `ChatController` with real-time streaming
- [x] Add chat cost tracking and limits (#1522) — token usage and spending caps per session
- [x] Add interactive chat UI with Stimulus controllers, sidebar, and streaming display (#1591)
- [x] Add chat container manager for workspace sessions (#1520)
- [x] Align chat interface design with Paid's existing design patterns (#1675)
- [x] Simplify chat setup with sensible defaults (#1673)

Deliverables:

- Users can start chat sessions linked to projects
- Real-time streaming responses via SSE
- Chat context includes project knowledge base
- Token usage tracked and capped per session

### 3.5.8 Knowledge Evolution

**Objective**: Automatically evolve the knowledge base by analyzing agent run outcomes and identifying gaps.

**RDR**: [RDR-027](rdrs/RDR-027-auto-enhance-knowledge-evolution.md)

Tasks:

- [x] Add `KnowledgeRecommendation` model with lifecycle states (#1513) — pending/accepted/dismissed/implemented
- [x] Add `knowledge_evolution_enabled` project setting (#1513)
- [x] Create `KnowledgeEvolutionJob` (GoodJob cron), `KnowledgeEvolutionWorkflow` (Temporal), and activities (#1524) — `SampleEnhanceRuns`, `AnalyzeKnowledgeGaps`, `RecordKnowledgeRecommendations`
- [x] Add `Knowledge::UsageStats` service and dashboard integration (#1504)
- [x] Add `KnowledgeUsageStat` model for per-artifact-type usage tracking (#1448)
- [x] Add KnowledgeRecommendation review UI for project owners (#1627) — accept/dismiss with Turbo Stream updates

Deliverables:

- Knowledge base evolves based on agent run feedback
- Per-artifact usage stats visible in dashboard
- Knowledge gaps surfaced as actionable recommendations

### 3.5.9 Configuration Experiments

**Objective**: Generalize A/B testing beyond prompts to any configuration parameter.

Tasks:

- [x] Extend A/B testing to non-prompt configuration experiments (#1410) — `ConfigurationExperiment`, `ConfigurationExperimentVariant`, `ConfigurationExperimentAssignment` models with full lifecycle
- [x] Integrate configuration experiments into `Knowledge::ContextBundle::Build` and `QualityMetrics::Collect`

Deliverables:

- Any configuration parameter can be A/B tested
- Results feed into quality metrics and knowledge context

### 3.5.10 Automation Strategy Extraction

**Objective**: Extract hardcoded automation policies into modular strategy classes for extensibility and future Phase 4 learned strategies.

**RDR**: [RDR-023](rdrs/RDR-023-automation-modularization-architecture.md)

Tasks:

- [x] Extract auto-merge into `Automation::Strategies::AutoMerge` strategy module (#1120, #1510)
- [x] Extract auto-continue into `Automation::Strategies::AutoContinue` strategy module (#1121, #1515)
- [x] Integrate `analyze_issue` gate into auto-pick strategy (#1475)
- [x] Add contract and parity tests for automation modules (#1631)
- [x] Thin workflows and jobs to orchestration-only (#1608)

Deliverables:

- Automation policies are modular and independently testable
- New strategies can be added without modifying orchestration workflows
- Foundation laid for Phase 4 learned orchestration strategies

### 3.5.11 Operational Infrastructure

**Objective**: Improve operational visibility and safe deployment capabilities.

Tasks:

- [x] Add operational alert rules for stalled PRs, runaway loops, and quota exhaustion (#1451)
- [x] Expose Flipper percentage rollout with progressive deployment UI (#1460) — `FeatureFlags.enable_percentage_of_actors`, `TenantConfigurationsController`
- [x] Add quality escalation to higher model tier (#1450) — `QualityRecovery::ModelEscalation` with learned defaults
- [x] Add tier usage and tier-vs-quality dashboards (#1455)
- [x] Add GitHub circuit breaker to pause dispatching during outages (#1502)
- [x] Add periodic GitHub token health check job (#1503)
- [x] Auto-pause projects when GitHub token is confirmed expired (#1505)
- [x] Add provider-contract smoke test for paid-agent image (#1318, #1487)
- [x] Surface in-progress phase in agent run timeline (#1509)
- [x] Move active runs above queue health in live dashboard (#1499)
- [x] Fix auto-merge CI verification to use Actions API for safe Dependabot merging (#1615)
- [x] Add queue preview showing upcoming work order with fair queue visibility (#1610)
- [x] Add stacked agent runs per day chart to dashboard (#1614)
- [x] Expose generic integration credentials in the integrations hub (#1617)

Deliverables:

- Operators receive proactive alerts for operational issues
- Progressive feature rollouts enable safe deployments
- Model tier escalation improves quality without manual intervention

### 3.5.12 MCP Server Support

**Objective**: Enable agents to use external tools during execution via the Model Context Protocol (MCP), and expose Paid operations as tools for the chat interface.

Tasks:

- [x] Add Paid MCP server for agent tool use (#1532) — JSON-RPC over SSE, 9 tools, rate limiting, container auth
- [x] Integrate MCP-enabled execution through agent-harness (#1660) — CLI flag translation per provider
- [x] Provision npx and docker-image MCP servers for agent runs (#1657) — `Containers::McpProvisioner`, sidecar lifecycle
- [x] Add Services-page and project configuration UI for MCP servers (#1664) — `McpServerDefinition`, `ProjectMcpServer` models

Deliverables:

- Agents access external tools during execution via MCP
- Project owners configure MCP servers from the UI
- Paid exposes its own operations as MCP tools for the chat interface
- Both npx-based and docker-image MCP server types supported

### 3.5.13 Screenshot & Visual Regression

**Objective**: Automatically capture screenshots of UI changes in PRs for visual review.

Tasks:

- [x] Add CI workflow to detect UI changes and capture rendered screenshots (#1623) — Cuprite/Chrome rendering, change detection
- [x] Inline image display in PR comments via orphan branch push (#1676) — raw.githubusercontent.com URLs, table layout, cleanup job
- [x] Resolve Ferrum base_url error in CI screenshot capture (#1663)

Deliverables:

- PRs with UI changes automatically include rendered screenshots
- Screenshots displayed inline in PR comments for easy review
- Visual diff visible without leaving GitHub

### 3.5.14 Agent Run Enhancements

**Objective**: Improve agent run reliability, observability, and capability with structural enhancements.

Tasks:

- [x] Generate decomposition plans with dependency ordering and DAG validation (#1656) — `DecompositionPlan::Generate`, `DecompositionPlan::ValidateDag`
- [x] Create multiple issues with dependency declarations in create-issue mode (#1658) — topological ordering, `Depends on #N` declarations
- [x] Integrate streaming JSONL progress events into container watchdog (#1602) — `StreamingEventProcessor` with progress/token tracking
- [x] Add pre-flight provider health check before agent execution (#1620) — auth, CLI availability, API reachability
- [x] Adopt agent-harness heartbeat support for OpenCode/KiloCode fallbacks (#1641) — upstream capability detection
- [x] Tie model selection to direct-outbound provider capabilities (#1670) — auto-populate tier_model_ids
- [x] Skip harness preflight for subscription-auth runners (#1680)
- [x] Implement provider fallback loop for knowledge base LLM calls (#1684) — `Knowledge::ProviderExecutor` with graceful degradation

Deliverables:

- Decomposition plans produce ordered, dependency-linked sub-issues
- Watchdog has semantic awareness of agent state via structured JSONL events
- Pre-flight checks prevent wasted container resources on misconfigured runners
- Knowledge base LLM calls are resilient to provider rate limits and errors

### 3.5.15 Self-Healing & Exception Handling

**Objective**: Capture, classify, and take action on application exceptions automatically.

Tasks:

- [x] Add centralized exception handling service with auto-issue filing and self-healing (#1531) — `ExceptionHandler::Handle`, `Fingerprinter`, `Classifier`, `IssueFiler`, `ExceptionIncident` model

Deliverables:

- Exceptions are fingerprinted and deduplicated
- P1/P2 errors auto-file GitHub issues with full context
- Exception history visible for incident response

### 3.5.16 Enhanced Notifications & Subscriptions

**Objective**: Allow users to subscribe to specific events and receive targeted notifications.

Tasks:

- [x] Allow users to subscribe to issue/PR merge events (#1609) — `IssueMergeSubscription`, per-user notification stream with Turbo Stream delivery

Deliverables:

- Users subscribe to individual issues and PRs for merge notifications
- Notification stream is per-user with real-time delivery

### 3.5.17 Dashboard & Observability Enhancements

**Objective**: Improve dashboard visibility with new visualizations and dark-mode support.

Tasks:

- [x] Add queue preview showing upcoming work order (#1610) — fair queue visibility with capacity display
- [x] Add stacked agent runs per day chart (#1614) — Chart.js visualization
- [x] Improve dark-mode contrast in dashboard quality pause info block (#1635)
- [x] Dashboard upcoming queue table: replace Created with Context and remove Waiting (#1636)
- [x] Move upcoming queue above queue health section (#1669)
- [x] Show agent run goal on main agent runs index page table (#1630)

Deliverables:

- Dashboard shows upcoming work order with fair queue visibility
- Historical agent run activity visible via stacked daily chart
- Dark-mode rendering consistent across all dashboard components

---

## Phase 4: AI-Native Evolution

**Goal**: The system learns and improves its own orchestration through data, applying the Bitter Lesson to agent coordination itself.

**Status**: Complete as of 2026-05-14. Tracked by umbrella issue #1818.

This phase represents Paid's evolution from a well-engineered orchestration platform to a genuinely self-improving system. The core insight: if general methods that leverage computation beat hand-crafted approaches for LLMs, the same may be true for LLM orchestration.

### 4.1 Orchestration Decision Logging

**Objective**: Capture all orchestration decisions with full context for later learning.

**Status**: Complete — orchestration decisions are stored as analyzable records with workflow context, analysis queries, and dashboard visibility.

Tasks:

- [x] Create `orchestration_decisions` table
- [x] Instrument workflows to log decomposition decisions
- [x] Log agent selection decisions with context
- [x] Log retry and escalation decisions
- [x] Build analysis queries for decision patterns
- [x] Dashboard showing orchestration metrics by context

Deliverables:

- 100% of orchestration decisions logged with context
- Analysis dashboard for decision patterns
- Foundation for all Phase 4 learning systems

Related: [RDR-014](rdrs/RDR-014-learned-orchestration.md)

### 4.2 Learned Orchestration Strategies

**Objective**: Orchestration strategies stored as data and evolved based on outcomes.

**Status**: Complete — strategies are versioned data, selected by context, evolved through workflow automation, and reviewed before promotion.

Tasks:

- [x] Create `strategies` and `strategy_versions` tables
- [x] Extract current hardcoded workflows into database strategies
- [x] Implement context-aware strategy selection
- [x] Create strategy evolution workflow (LLM-based mutation)
- [x] A/B test evolved strategies against baseline
- [x] Human review gate for strategy changes

Deliverables:

- Orchestration strategies as database entities
- Context-based strategy selection working
- First evolved strategy promoted via A/B test

Related: [RDR-014](rdrs/RDR-014-learned-orchestration.md)

### 4.3 End-to-End Outcome Optimization

**Objective**: Optimize entire configuration bundles (prompts + models + strategies) based on final outcomes.

**Status**: Complete — configuration bundles are tracked end-to-end, optimized with a Bayesian selector, and exposed through performance analysis tooling.

Tasks:

- [x] Create `configuration_bundles` and `bundle_outcomes` tables
- [x] Implement configuration bundle tracking per agent run
- [x] Build surrogate model (Random Forest initially, GP later)
- [x] Implement Bayesian optimization for bundle selection
- [x] Exploration/exploitation balance with context awareness
- [x] Dashboard for bundle performance analysis

Deliverables:

- Configuration bundles versioned and tracked
- Bayesian optimizer selecting bundles for new tasks
- Measurable improvement in outcome/cost ratio

Related: [RDR-015](rdrs/RDR-015-end-to-end-optimization.md)

### 4.4 Self-Improving Agent Coordination

**Objective**: Coordination policies (decomposition, assignment, retry, escalation) evolve from outcomes.

**Status**: Complete — coordination policies are explicit data, evolved from results, and validated through experiment-driven promotion paths.

Tasks:

- [x] Create coordination policy data model
- [x] Implement `DecompositionService` with policy-based rules
- [x] Implement `FailureRecoveryService` with learned failure classification
- [x] Implement `EscalationService` with human-value prediction
- [x] Create policy evolution workflow
- [x] A/B test evolved policies

Deliverables:

- All coordination decisions driven by evolvable policies
- Failure classification improves from data
- Escalation predictions validated against actual human value

Related: [RDR-016](rdrs/RDR-016-self-improving-coordination.md)

### 4.5 Orchestration Scaling Laws

**Objective**: Discover and apply scaling laws for agent orchestration.

**Status**: Complete — scaling experiments, confidence intervals, and a scaling-aware allocator now inform orchestration resource decisions.

Tasks:

- [x] Create scaling observation instrumentation
- [x] Design controlled experiments for scaling dimensions
- [x] Run agent count scaling experiment
- [x] Run iteration count scaling experiment
- [x] Analyze parallelism effects
- [x] Implement scaling-based resource allocator

Deliverables:

- Scaling exponents estimated for key dimensions
- Diminishing returns thresholds identified
- Dynamic allocation improves efficiency by 10%+

Related: [RDR-017](rdrs/RDR-017-orchestration-scaling-laws.md)

### Phase 4 Completion Criteria

- [x] All orchestration decisions logged and analyzable
- [x] At least one orchestration strategy evolved and promoted via A/B test
- [x] End-to-end optimization shows measurable improvement
- [x] Coordination policies adapt based on measured outcomes
- [x] Scaling laws documented with confidence intervals
- [x] System demonstrably improves with more data/compute

**Phase 4 completed**: All AI-native orchestration objectives verified as of 2026-05-14.

---

## Phase 5: Account Administration

**Goal**: Make account, tenant, and user management safe and visible without requiring Rails console access.

This phase separates internal operator administration from customer-facing account management. The operator console should arrive first through Avo as a fast, constrained backoffice. The product account admin surface should be native Rails/Hotwire UI for account owners and admins.

Related: [RDR-026](rdrs/RDR-026-admin-interface-strategy.md), [RDR-010](rdrs/RDR-010-multi-tenancy-rbac.md), [RDR-024](rdrs/RDR-024-multi-tenancy-isolation-strategy.md)

### 5.1 Avo Operator Console

**Objective**: Give maintainers an internal admin console for tenant/account operations.

Tasks:

- [ ] Implement Avo operator console as a single focused issue
- [ ] Confirm Avo edition/license supports required auth, field controls, and actions
- [ ] Mount `/admin` behind a fail-closed operator-only access gate
- [ ] Add Avo resources for `Account`, `User`, `AccountMembership`, `ProjectMembership`, and `TenantSetting`
- [ ] Configure Devise `current_user` and Pundit resource authorization
- [ ] Hide or mask sensitive credential/token fields
- [ ] Disable dangerous raw deletes by default
- [ ] Add explicit account lifecycle actions where supported by model APIs
- [ ] Add access-control specs proving non-operator account owners/admins are denied
- [ ] Document operator-console boundaries and runbook usage

Deliverables:

- Operators can inspect and correct account/user/tenant state without console access
- Non-operators, including account owners/admins, cannot access the admin console
- Sensitive data is not exposed through admin resources
- Destructive actions are constrained to explicit lifecycle flows

### 5.2 User-Facing Account Administration

**Objective**: Give account owners/admins a polished product UI for managing their own account.

Tasks:

- [ ] Account profile/settings edit UI
- [ ] User invitation flow
- [ ] Membership list with role changes and removals
- [ ] Ownership transfer workflow
- [ ] Tenant settings and quota visibility
- [ ] Account lifecycle request flow where appropriate
- [ ] Billing plan, usage, invoices, and payment status UI once billing models are wired
- [ ] Audit log or activity trail for account-management changes

Deliverables:

- Account owners/admins can manage users and roles without operator help
- Account settings and tenant limits are visible from the product UI
- Billing/account lifecycle surfaces are ready for SaaS operation
- Avo remains an internal backoffice, not the customer-facing account admin

### Phase 5 Completion Criteria

- [ ] Operator admin console is available and access-controlled
- [ ] Account owners/admins can invite users and manage memberships
- [ ] Account settings and tenant limits are editable through product UI
- [ ] Ownership transfer and lifecycle actions are audited
- [ ] Billing/account information is visible to authorized owners/admins

---

## Phase 6: Enterprise Trust & Governance

**Goal**: Remove the trust, governance, and procurement blockers that keep mature engineering organizations from adopting Paid for production software delivery.

This phase turns Paid from a capable internal system into something a security team, platform team, and VP Engineering can approve with confidence.

### 6.1 GitHub App & Enterprise Identity

**Objective**: Replace PAT-heavy onboarding with enterprise-grade identity, repository authorization, and organization deployment flows.

Tasks:

- [ ] Implement GitHub App authentication for repo access, PR creation, and webhook setup
- [ ] Add migration path from PAT-backed projects to GitHub App-backed projects
- [ ] Support mixed-mode org rollout (some repos on PAT, some on GitHub App) during transition
- [ ] Add SSO/SAML/OIDC support for user authentication
- [ ] Add SCIM or equivalent user lifecycle sync for enterprise accounts
- [ ] Add org-level installation, approval, and repository-scoping UX

Deliverables:

- Enterprise customers can onboard repositories without distributing personal PATs
- Identity and repository access align with enterprise security expectations
- Large org rollouts are operationally manageable

### 6.2 Audit Logging & Forensics

**Objective**: Provide a complete, queryable audit trail for security, compliance, and incident response.

Tasks:

- [ ] Create system-wide audit event model covering auth, project changes, runner changes, runs, approvals, and automation policy changes
- [ ] Record actor, target, before/after state, request metadata, and tenant context for all sensitive operations
- [ ] Add immutable audit-log export APIs and retention controls
- [ ] Add audit-log search and filtering UI for operators and account admins
- [ ] Add incident-ready run provenance linking prompts, models, tools, code changes, and approvals

Deliverables:

- Security teams can answer who changed what, when, and why
- Regulated customers have exportable evidence for reviews and investigations
- Agent behavior is forensically traceable end to end

### 6.3 Policy, Risk & Approval Controls

**Objective**: Give enterprises fine-grained control over what agents may do, when humans must approve, and how model/runner risk is bounded.

Tasks:

- [ ] Add policy engine for runner allowlists, model allowlists, max capability tiers, and network/service-container restrictions
- [ ] Add configurable approval workflows by repo, branch, issue type, risk score, or change surface
- [ ] Add environment-specific controls for production, staging, and regulated codebases
- [ ] Add DLP-style redaction and prompt/context classification rules
- [ ] Add policy simulation mode to preview what would have happened under a proposed ruleset

Deliverables:

- Enterprises can encode their SDLC and AI-risk policies directly in Paid
- High-risk work is gated without blocking low-risk automation
- Security reviews move from ad hoc trust to enforceable controls

### 6.4 Compliance & Deployment Assurance

**Objective**: Make Paid easier to buy by supplying compliance evidence and hardened deployment patterns.

Tasks:

- [ ] Publish hardened deployment reference architectures for self-hosted, private VPC, and air-gapped variants
- [ ] Add compliance evidence pack generation (control mappings, configuration snapshots, audit exports)
- [ ] Add customer-managed key support and secret-rotation workflows
- [ ] Add disaster recovery, backup/restore, and upgrade runbooks with validation tooling
- [ ] Add compliance dashboard showing gaps against required controls

Deliverables:

- Platform and security teams can assess deployment posture quickly
- Compliance programs have concrete artifacts instead of bespoke questionnaires
- Paid is viable in more security-sensitive environments

### Phase 6 Completion Criteria

- [ ] GitHub App onboarding is production-ready and preferred over PAT onboarding
- [ ] System-wide audit logging covers all security- and operations-relevant mutations
- [ ] Policy and approval controls can enforce enterprise rollout guardrails
- [ ] Hardened deployment patterns and compliance evidence are documented and testable

---

## Phase 7: Proof, Adoption & Interoperability

**Goal**: Make Paid easy to justify commercially by proving ROI, fitting into existing toolchains, and reducing switching risk from commercial alternatives.

This phase is about winning deals. Mature buyers need more than features; they need proof, benchmarks, migration paths, and confidence that Paid can coexist with what they already use.

### 7.1 ROI, Evals & Benchmarking

**Objective**: Quantify Paid's value in language engineering leaders and procurement teams can use to make buying decisions.

Tasks:

- [ ] Create evaluation framework for merge rate, cycle time, rework rate, defect escape rate, and cost per accepted PR
- [ ] Add side-by-side benchmark support versus baseline human-only flow and commercial agent tools
- [ ] Add per-project and per-account ROI dashboards with trend analysis
- [ ] Add experiment templates for pilot programs ("2-week bug-fix pilot", "backlog burn-down pilot")
- [ ] Add executive summaries and exportable reports for stakeholder review

Deliverables:

- Paid can prove business value with customer-specific evidence
- Sales and customer success teams have repeatable pilot and benchmark motions
- Expansion decisions can be based on measured outcomes, not anecdotes

### 7.2 Migration, Coexistence & Toolchain Interop

**Objective**: Reduce adoption friction by letting Paid coexist with incumbent tools and workflows.

Tasks:

- [ ] Add integration patterns for GitHub Copilot, Cursor, Devin, Factory, and internal agent workflows where technically feasible
- [ ] Add import/mapping flows for existing prompts, style guides, and workflow policies
- [ ] Add connectors and event ingestion for Jira, Linear, GitLab, Bitbucket, Slack, Teams, and CI systems
- [ ] Add external execution ingestion so Paid dashboards can compare third-party agent outcomes with Paid-native runs
- [ ] Add gradual adoption modes: observe-only, advisory, review-only, and full execution

Deliverables:

- Customers can adopt Paid without ripping out existing developer tools on day one
- Paid becomes the control plane and measurement layer before it becomes the full execution layer
- Switching risk drops materially

### 7.3 Change Management & Operational Readiness

**Objective**: Help mature companies operationalize Paid across platform, engineering, and security teams.

Tasks:

- [ ] Add admin playbooks for pilot rollout, guardrail tuning, and operating-model design
- [ ] Add training and onboarding flows for developers, reviewers, managers, and platform admins
- [ ] Add adoption analytics (active teams, usage depth, automation acceptance rate, manual override rate)
- [ ] Add in-product recommendations for underutilized features and rollout blockers
- [ ] Add reference operating models for centralized platform ownership vs team-owned deployments

Deliverables:

- Customers can move from pilot to production rollout with less bespoke consulting
- Adoption blockers are visible early
- Paid usage expands through repeatable operational patterns

### Phase 7 Completion Criteria

- [ ] ROI and evaluation dashboards are available at project and account scope
- [ ] Paid can benchmark itself against alternative workflows and tools
- [ ] Customers can adopt Paid in observe-only or coexistence modes before full automation
- [ ] Rollout and change-management guidance is productized

---

## Phase 8: Managed Platform & Ecosystem

**Goal**: Make Paid purchasable by organizations that want the benefits of the platform without operating all of its infrastructure themselves.

This phase broadens the market from companies willing to self-host orchestration infrastructure to companies that want a managed or semi-managed product with enterprise operations behind it.

### 8.1 Managed Deployment Models

**Objective**: Support customer-preferred operating models without fragmenting the product.

Tasks:

- [ ] Build fully managed cloud offering with tenant isolation, backups, monitoring, and upgrades
- [ ] Build private SaaS / single-tenant hosted option for enterprise customers
- [ ] Build bring-your-own-cloud deployment automation with validated reference stacks
- [ ] Define upgrade channels, maintenance windows, and version-support policy

Deliverables:

- Customers can choose managed, private, or self-hosted deployment models
- Operational burden drops significantly for non-platform-heavy buyers
- Sales can match deployment model to customer security posture

### 8.2 Enterprise Operations & Reliability

**Objective**: Deliver the reliability, supportability, and lifecycle management expected of an enterprise product.

Tasks:

- [ ] Add SLA/SLO framework with customer-visible uptime and queue-health reporting
- [ ] Add automated backups, restore drills, and customer-facing disaster recovery commitments
- [ ] Add fleet-wide upgrade orchestration and compatibility checks
- [ ] Add support tooling for tenant diagnostics, safe remediation, and health reporting
- [ ] Add cost controls and capacity-management tooling for managed environments

Deliverables:

- Paid can be sold with clear operational expectations
- Support teams can diagnose and remediate tenant issues safely
- Reliability posture is legible to enterprise buyers

### 8.3 Marketplace & Ecosystem Expansion

**Objective**: Increase Paid's strategic value by making it extensible and ecosystem-friendly.

Tasks:

- [ ] Create plugin/extension model for custom collectors, policies, tools, and workflow strategies
- [ ] Add marketplace or curated catalog for integrations, prompts, and policy packs
- [ ] Add partner-friendly APIs for system integrators and internal platform teams
- [ ] Publish ecosystem certification guidance for supported extensions

Deliverables:

- Paid can grow through customer and partner extensions
- Specialized domains can be supported without product-core bloat
- The platform becomes stickier over time

### Phase 8 Completion Criteria

- [ ] Managed and private deployment models are generally available
- [ ] Enterprise operations meet documented SLO/SLA expectations
- [ ] Ecosystem extension points are stable enough for customers and partners to build on

---

## Future Considerations (Beyond Phase 8)

These are not committed but worth keeping in mind:

### Additional Integrations

- Deeper ERP/procurement integrations for large enterprise buying motions
- ServiceNow integration
- Internal developer portal integrations (Backstage, etc.)

### Advanced Agent Capabilities

- Agent collaboration (agents reviewing each other's work)
- Specialized agents (security review, performance optimization)
- Custom agent development framework

### Enterprise Features

- Industry-specific policy packs and control mappings
- Regional/data-sovereignty deployment options
- Advanced reviewer workload balancing and approval routing

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
Phase 2.7 (Semantic Search) ─────────────────────────────────────►

Phase 3 (Scale) ─────────────────────────────────────────────────►
          │
          └── 3.5 (Completion & Hardening) ────────────────────►
                    │
                    └── 4.1 (Decision Logging) ─── prerequisite gate

Phase 4 (AI-Native Evolution) ───────────────────────────────────►
          │
          └── 5.1 (Avo Operator Console) ───────────────────────►
                    │
                    └── 5.2 (User-Facing Account Admin) ───────►
                              │
                              └── Phase 6 (Enterprise Trust & Governance) ──►
                                           │
                                           └── Phase 7 (Proof, Adoption & Interop) ──►
                                                        │
                                                        └── Phase 8 (Managed Platform & Ecosystem)
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
| Phase 4 premature | Phase 3.5 completion gate ensures foundations are solid |
| Enterprise sales drag | Phase 6 and 7 convert trust gaps into roadmap commitments |
| Operational burden blocks adoption | Phase 8 adds managed deployment and enterprise operations |

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
- Projects indexed on creation, semantic search < 500ms
- Dashboard latency < 1 second

### Phase 3

- 5+ agents running in parallel
- Prompt evolution shows measurable improvement
- Quality gates catch 90% of regressions
- Performance handles 10 concurrent projects

### Phase 3.5

- Zero open P1 security or data integrity issues
- A/B tests producing quality data from ≥ 20 live runs
- enhance_issue goal: end-to-end with knowledge, quality, and re-evaluation
- Multi-runner automatic selection working with fallback
- Fair queueing: no user starvation under load
- Performance: 10 concurrent projects with P95 container startup < 30s
- MCP servers: agents successfully use external tools during execution
- Chat: streaming responses with cost tracking and container workspace
- Self-healing: P1/P2 exceptions auto-file issues with fingerprint deduplication
- Screenshots: visual diff captured automatically for PRs with UI changes

### Phase 4

- 100% of orchestration decisions logged and analyzable
- Learned orchestration strategies outperform hand-designed by 10%+
- End-to-end optimization improves outcome/cost ratio by 15%+
- Scaling laws estimated with 95% confidence intervals
- System shows measurable improvement month-over-month from learning

### Phase 5

- Operators can manage tenant/account state without Rails console access
- 100% of admin-console access is operator-gated
- Account owners/admins can invite users and manage roles from product UI
- Account lifecycle and ownership changes are auditable
- Sensitive credential/token material is not exposed in account/admin screens

### Phase 6

- 90%+ of new enterprise projects onboard through GitHub App rather than PAT
- 100% of security-relevant mutations appear in audit logs with actor and tenant context
- Policy engine can enforce repo/model/runner restrictions with no manual console intervention
- Compliance evidence can be exported for a customer security review in < 1 hour

### Phase 7

- Paid can show customer-specific ROI within the first 30 days of a pilot
- Side-by-side evaluations demonstrate clear advantage or clear fit boundaries versus alternatives
- At least one coexistence deployment path is available for each major incumbent workflow
- Pilot-to-production conversion rate improves through packaged rollout motions

### Phase 8

- Managed offering meets published uptime and support commitments
- Median customer onboarding time drops materially versus self-host-only deployments
- Private deployment upgrades complete with validated rollback paths
- Ecosystem extensions account for a meaningful share of advanced customer deployments

---

## Getting Started

1. Clone this repository
2. Review [ARCHITECTURE.md](./ARCHITECTURE.md) for system design
3. Review [db/schema.rb](../db/schema.rb) for the canonical database schema
4. Start with Phase 1.1: Rails Application Skeleton
5. Use the task lists above as implementation checklists

Each phase builds on the last. Don't skip ahead—the foundation matters.
