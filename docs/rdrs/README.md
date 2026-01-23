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
| Final | Locked, ready for or during implementation |
| Implemented | Implementation complete |
| Abandoned | RDR not implemented |
| Superseded | Replaced by another RDR |

## Index

### Foundation (Core Technology Stack)

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-001](RDR-001-web-framework-selection.md) | Web Framework Selection (Rails) | Final | High |
| [RDR-002](RDR-002-workflow-orchestration.md) | Workflow Orchestration (Temporal.io) | Final | High |
| [RDR-003](RDR-003-database-selection.md) | Database Selection (PostgreSQL) | Final | High |

### Security & Isolation

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-004](RDR-004-container-isolation.md) | Container Isolation Strategy | Final | High |
| [RDR-005](RDR-005-git-worktree-management.md) | Git Worktree Management | Final | High |
| [RDR-006](RDR-006-secrets-proxy.md) | Secrets Proxy Architecture | Final | High |

### Agent System

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-007](RDR-007-agent-cli-abstraction.md) | Agent CLI Abstraction (paid-agents gem) | Final | High |
| [RDR-008](RDR-008-model-selection.md) | Model Selection Strategy | Final | Medium |

### Intelligence

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-009](RDR-009-prompt-evolution.md) | Prompt Evolution System | Final | High |

### Operations & Access

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-010](RDR-010-multi-tenancy-rbac.md) | Multi-Tenancy and RBAC | Final | Medium |
| [RDR-011](RDR-011-observability.md) | Observability Stack | Final | Medium |

### External Integration

| RDR | Title | Status | Priority |
|-----|-------|--------|----------|
| [RDR-012](RDR-012-github-integration.md) | GitHub Integration Strategy | Final | High |

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
- **Authorization**: Rolify + Pundit for RBAC

### Agent Execution
- **CLI Abstraction**: paid-agents gem with adapters for Claude Code, Cursor, Codex, Copilot
- **Model Selection**: LLM-based meta-agent with rules fallback
- **Prompts**: Database-stored with A/B testing and automated evolution

### Operations
- **Observability**: Prometheus + Grafana stack
- **Multi-tenancy**: Account-based isolation from day one
- **GitHub**: PAT-based polling with graceful degradation

## RDR Lifecycle

1. **Create**: Initial documentation of problem and constraints
2. **Research**: Investigation, findings integration, alternative exploration
3. **Finalize**: Lock before development; status becomes "Final"
4. **Implement**: Use as specification; no modifications during coding
5. **Post-Mortem**: Update status; create addendum for lessons learned

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
