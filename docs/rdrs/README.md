# Paid Recommendation Decision Records (RDRs)

This directory contains Recommendation Decision Records for Paid's major architectural decisions.

## What are RDRs?

RDRs are specification prompts built through iterative research and refinement. Unlike Architecture Decision Records (ADRs), which document completed decisions, RDRs evolve during the planning phase as understanding deepens and viable options crystallize into a recommended approach.

The central objective is to capture both the final solution and supporting evidence to prevent purpose drift during implementation.

For more information, see the [RDR methodology](https://github.com/cwensel/rdr).

## RDR Status

| Status | Meaning |
|--------|---------|
| Draft | During planning/research phase |
| Accepted | Recommendation accepted but implementation not started |
| Final | Locked, ready for or during implementation |
| Partially Implemented | Adopted and partly shipped, with remaining implementation work tracked |
| Implemented | Implementation complete |
| Abandoned | RDR not implemented |
| Superseded | Replaced by another RDR |

## Index

### Foundation (Core Technology Stack)

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-001](RDR-001-web-framework-selection.md) | Web Framework Selection (Rails) | Implemented | High |
| [RDR-002](RDR-002-workflow-orchestration.md) | Workflow Orchestration (Temporal.io) | Implemented | High |
| [RDR-003](RDR-003-database-selection.md) | Database Selection (PostgreSQL) | Implemented | High |

### Security & Isolation

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-004](RDR-004-container-isolation.md) | Container Isolation Strategy | Implemented | High |
| [RDR-005](RDR-005-git-worktree-management.md) | Git Worktree Management | Superseded | High |
| [RDR-006](RDR-006-secrets-proxy.md) | Secrets Proxy Architecture | Implemented | High |
| [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md) | Subscription Runner Managed Auth Lifecycle | Partially Implemented | P1 |

### Agent System

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-007](RDR-007-agent-cli-abstraction.md) | Agent CLI Abstraction (agent-harness gem) | Implemented | High |
| [RDR-008](RDR-008-model-selection.md) | Model Selection Strategy | Implemented | Medium |
| [RDR-034](RDR-034-tier-based-runner-fallback.md) | Tier-Based Runner Fallback | Implemented | P1 |

### Intelligence

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-009](RDR-009-prompt-evolution.md) | Prompt Evolution System | Implemented | High |

### Operations & Access

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-010](RDR-010-multi-tenancy-rbac.md) | Multi-Tenancy and RBAC | Implemented | Medium |
| [RDR-011](RDR-011-observability.md) | Observability Stack | Partially Implemented | Medium |
| [RDR-039](RDR-039-exception-notification-custom-notifier.md) | Exception Reporting via `exception_notification` Custom Notifier | Implemented | P2 |
| [RDR-018](RDR-018-billing-aggregation.md) | Billing Aggregation System | Implemented | P2 |
| [RDR-024](RDR-024-multi-tenancy-isolation-strategy.md) | Multi-Tenancy Isolation Strategy | Implemented | High |
| [RDR-026](RDR-026-admin-interface-strategy.md) | Admin Interface Strategy | Implemented | Medium |
| [RDR-029](RDR-029-multi-tenancy-preparation.md) | Multi-Tenancy Preparation | Implemented | High |

### External Integration

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-012](RDR-012-github-integration.md) | GitHub Integration Strategy | Partially Implemented | High |
| [RDR-030](RDR-030-github-app-bot-account.md) | GitHub App Bot Account for Repository Actions | Partially Implemented | High |

### Service Infrastructure

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-020](RDR-020-service-container-architecture.md) | Service Container Architecture | Implemented | High |

### Interactive Chat

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-028](RDR-028-interactive-chat.md) | Interactive Chat for Agent-Driven Development | Implemented | High |
| [RDR-037](RDR-037-containerized-multi-repo-chat.md) | Containerized Multi-Repo Chat Sessions | Final | High |
| [RDR-044](RDR-044-configuration-profiles-chat.md) | Chat-Driven Configuration Profiles (Operating Modes) | Draft | High |

### Scaling & Distribution

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-019](RDR-019-remote-container-execution.md) | Remote Container Execution | Implemented | Medium |
| [RDR-033](RDR-033-worker-pool-scaling-algorithm.md) | Worker Pool Scaling Algorithm | Implemented | Medium |
| [RDR-043](RDR-043-zero-config-docker-capacity-autoscaling.md) | Zero-Config Docker Capacity Autoscaling | Implemented | Medium |
| [RDR-048](RDR-048-multi-host-docker-backend-support.md) | Multi-Host Docker Backend Support | Draft | P1 |

### Quality & Automation

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-013](RDR-013-code-quality-backpressure.md) | Code Quality and Backpressure System | Superseded | High |
| [RDR-022](RDR-022-auto-merge-pr-strategy.md) | Auto-Merge PR Merge Strategy | Implemented | Medium |
| [RDR-023](RDR-023-automation-modularization-architecture.md) | Automation Modularization Architecture | Partially Implemented | High |
| [RDR-031](RDR-031-focused-agent-runs.md) | Focused Agent Runs — Single-Problem-Per-Run | Implemented | P1 |
| [RDR-032](RDR-032-eager-queue-seeding.md) | Eager Queue Seeding — Eliminate Auto-Pick Throttling | Implemented | P1 |
| [RDR-035](RDR-035-style-guide-evolution.md) | Style Guide Evolution | Accepted | High |
| [RDR-036](RDR-036-mutation-testing-for-ai-generated-tests.md) | Mutation Testing for AI-Generated Tests (Mutant) | Partially Implemented | P1 |
| [RDR-045](RDR-045-live-web-app-preview-agent-verification.md) | Live Web App Preview and Interactive Agent Verification | Draft | High |
| [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md) | Polyglot Language Detection and Test Execution | Draft | High |
| [RDR-047](RDR-047-work-category-queue-priority.md) | Work-Category-Aware Queue Priority — PR Continuation Over Fresh Issues | Implemented | P1 |

### Runner Intelligence

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-025](RDR-025-runner-quota-tracking.md) | Runner Quota Tracking and Quota-Aware Routing | Partially Implemented | Medium |
| [RDR-025](RDR-025-provider-quota-tracking.md) | Provider Quota Tracking and Quota-Aware Routing | Superseded | Medium |
| [RDR-038](RDR-038-free-models-catalog-and-runner.md) | Free Models Catalog and Runner | Partially Implemented | P1 |
| [RDR-040](RDR-040-runner-model-compatibility-contracts.md) | Runner Model Compatibility Contracts | Partially Implemented | P1 |

### Semantic Understanding

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-018](RDR-018-semantic-code-search.md) | Semantic Code Search (Qdrant + PostgreSQL full-text) | Implemented | Medium |
| [RDR-021](RDR-021-knowledge-base.md) | Knowledge Base Architecture | Implemented | High |
| [RDR-027](RDR-027-auto-enhance-knowledge-evolution.md) | Auto-Enhance and Knowledge Base Evolution | Partially Implemented | High |
| [RDR-042](RDR-042-change-intent-records.md) | Change Intent Records for the Knowledge Base | Accepted | Medium |

### AI-Native Evolution (Phase 4)

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-014](RDR-014-learned-orchestration.md) | Learned Orchestration Strategies | Implemented | Medium |
| [RDR-015](RDR-015-end-to-end-optimization.md) | End-to-End Outcome Optimization | Implemented | Medium |
| [RDR-016](RDR-016-self-improving-coordination.md) | Self-Improving Agent Coordination | Implemented | Medium |
| [RDR-017](RDR-017-orchestration-scaling-laws.md) | Orchestration Scaling Laws | Implemented | Low |

## Decision Summary

### Core Stack

- **Framework**: Rails 8+ with Hotwire for real-time UI
- **Database**: PostgreSQL with JSONB for flexible configuration
- **Workflows**: Temporal.io for durable, long-running operations
- **Background Jobs**: GoodJob for lightweight tasks, Temporal for complex workflows

### Security Model

- **Container Isolation**: Docker with hardened images, capability dropping
- **Secrets**: Proxy pattern—agents never see API keys
- **Git Isolation**: Worktrees for parallel agent work
- **Authorization**: Explicit membership tables + Pundit for RBAC

### Agent Execution

- **CLI Abstraction**: agent-harness gem with providers for Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, Kilocode, Pi
- **Model Selection**: LLM-based meta-agent with rules fallback
- **Prompts**: Database-stored with A/B testing and automated evolution

### Operations

- **Observability**: Prometheus + Grafana stack
- **Multi-tenancy**: Account-based isolation from day one
- **GitHub**: PAT-based polling with graceful degradation

### Quality & Automation

- **Backpressure**: Immediate feedback loops for agent self-correction
- **Git Hooks**: Pre-commit/pre-push guardrails (RuboCop, Brakeman, etc.)
- **CI Pipeline**: Comprehensive quality and security checks
- **Project Configuration**: Auto-detect language and configure appropriate tools

### AI-Native Evolution

- **Learned Orchestration**: Orchestration strategies as data, evolved via A/B testing
- **End-to-End Optimization**: Bayesian optimization of full configuration bundles
- **Self-Improving Coordination**: Decomposition, retry, escalation policies evolve from outcomes
- **Scaling Laws**: Empirical discovery of orchestration scaling behaviors

## RDR Lifecycle

1. **Create**: Initial documentation of problem and constraints
2. **Research**: Investigation, findings integration, alternative exploration
3. **Finalize**: Lock before development; status becomes "Final"
4. **Implement**: Use as specification; no modifications during coding
5. **Close Out**: Use a final audit issue that depends on the implementation chain. That issue updates the RDR and README statuses to "Implemented" only after validating the shipped implementation against the RDR plan and acceptance criteria. If gaps are found, it creates specific dependent follow-up issues and leaves the RDR status unchanged or "Partially Implemented".
6. **Post-Mortem**: Add lessons learned after implementation, when useful.

**Critical Rule**: If implementation exposes fundamental flaws in an RDR, abandon the code, incorporate learnings back into the RDR, and restart.

## Creating New RDRs

Use the template at the [RDR repository](https://github.com/cwensel/rdr/blob/main/TEMPLATE.md) as a starting point.

Key sections:

- **Problem Statement**: What challenge are we addressing?
- **Context**: Background and technical environment
- **Research Findings**: Evidence from investigation
- **Proposed Solution**: Technical design with rationale
- **Alternatives Considered**: Options explored and why rejected
- **Trade-offs**: Positive/negative consequences, risks
- **Implementation Plan**: Prerequisites, steps, files to modify
- **Validation**: Testing approach and scenarios

## Related Documents

- [VISION.md](../VISION.md) - Project philosophy and principles
- [ARCHITECTURE.md](../ARCHITECTURE.md) - System architecture overview
- [ROADMAP.md](../ROADMAP.md) - Implementation phases
- [DATA_MODEL.md](../DATA_MODEL.md) - Database schema design
- [AGENT_SYSTEM.md](../AGENT_SYSTEM.md) - Agent execution details
- [PROMPT_EVOLUTION.md](../PROMPT_EVOLUTION.md) - Prompt management
- [SECURITY.md](../SECURITY.md) - Security architecture
- [OBSERVABILITY.md](../OBSERVABILITY.md) - Monitoring design
- [STYLE_GUIDE.md](../STYLE_GUIDE.md) - Development conventions
