# Paid Glossary

This glossary defines terms specific to the Paid platform that are not industry-standard. It serves as the canonical reference for consistent naming across the codebase, UI, documentation, and discussions.

**Motivation**: PR #1950 (rename providers to runners) highlighted that ambiguous terminology causes confusion. This glossary prevents that class of problem from recurring.

## Core Domain

| Term | Definition |
|------|-----------|
| **Agent Run** | A single execution of a runner against a task (issue, PR review, etc.). Tracks lifecycle from queued to running to completed/failed. Core domain object (`AgentRun` model). |
| **Focused Agent Run** | An agent run scoped to a single, narrow problem class (e.g., CI fix, review response) rather than all PR problems at once. See RDR-031. |
| **Runner** | A code execution backend (e.g., Claude Code, Copilot, Aider, OpenCode, Kilocode) that performs agent work. Formerly called "Provider" in code. Renamed in #1950. NOT the same as an LLM provider. |
| **Runner State** | The operational status record for a runner (healthy, degraded, circuit-open, etc.). Formerly `provider_states`. Renamed in #1950. |
| **Runner Key** | The unique identifier string for a specific runner (e.g., `claude_code`, `copilot`). Formerly `provider_key`. Renamed in #1950. |
| **Agent Harness** | The shared execution framework (`agent_harness` gem) that wraps individual runners, providing plan-only APIs, heartbeats, and lifecycle management. All LLM calls must go through this gem. |

## Orchestration

| Term | Definition |
|------|-----------|
| **Auto-Pick** | The system that automatically selects and queues GitHub issues for agent runs based on priority, labels, and project settings. Distinct from manual issue assignment. |
| **Strategy** | A database-backed configuration (`Strategy`/`StrategyVersion` models) that defines how agent workflows execute: retry logic, decomposition rules, escalation thresholds. Evolved via A/B testing. |
| **Configuration Bundle** | A snapshot of all tunable parameters for an agent run (model, temperature, tools, strategy) tracked for Bayesian optimization. `ConfigurationBundle` model. |
| **Orchestration Decision** | A logged record of why the system chose a particular runner, decomposition, or retry path. Used for observability and scaling analysis. |
| **Coordination Policy** | Rules governing how multiple concurrent agent runs interact, avoid conflicts, and escalate. Evolved via the coordination evolution workflow. |
| **Decomposition** | Breaking a complex issue into smaller sub-tasks that can be handled by individual agent runs. Policy-based via `DecompositionService`. |
| **Escalation** | Promoting an agent run issue to human review when confidence is low or the task exceeds agent capability. Driven by `EscalationService` with human-value prediction. |
| **Optimizer** | The Bayesian optimization system that ranks runner/configuration candidates and balances exploration vs. exploitation. `Optimizer.ranked_candidates`. |

## Infrastructure

| Term | Definition |
|------|-----------|
| **Workspace** | The isolated filesystem environment (Docker volume or local directory) where a runner executes code changes. Container-managed via Docker or Swarm backend. |
| **Circuit Breaker** | Per-runner failure tracking that temporarily disables a runner after repeated failures. Transitions between closed/open/half-open states on `RunnerState`. |
| **Smoke Test / Test Agent** | A lightweight validation run that verifies a runner is functional (auth works, CLI responds). Used for health checks and onboarding. |
| **Watchdog** | A background thread that monitors running agent containers for hangs, timeouts, and silent failures via heartbeat-based liveness detection. |
| **Tenant** | A top-level organizational unit (GitHub org or team) that owns projects, users, runners, and settings. Multi-tenancy boundary. |

## External Integrations

| Term | Definition |
|------|-----------|
| **LLM Provider** | An upstream AI model vendor (OpenAI, Anthropic, Google, etc.) that supplies the language model a runner uses. Intentionally distinct from "Runner". Kept as `ProviderApiKey`, `LlmModel.provider`. |
| **PR Scanner** | The subsystem that monitors open PRs for review readiness, auto-merge eligibility, and escalation triggers. Rescans on state changes. |
| **Knowledge Base (KB)** | Project-specific context documents and business questionnaire answers injected into agent run prompts. Evolves via `KnowledgeEvolutionJob`. |

## Terms Intentionally Retaining "Provider"

These terms refer to LLM providers (not runners) and were intentionally kept during the #1950 rename:

- `ProviderApiKey` — API key for an LLM provider
- `LlmModel.provider` — which LLM vendor supplies a model
- `DIRECT_OUTBOUND_API_PROVIDERS` — upstream LLM API vendors
- `auth_provider` on `agent_runs` — LLM auth context
- `Automation::Providers::` namespace — external SDK/integration concept

## References

- [#1950](https://github.com/paidplatform/paid/pull/1950) — feat(runners): rename providers to runners (phase 1)
- [#1945](https://github.com/paidplatform/paid/issues/1945) — original issue motivating the rename
- [RDR-031](docs/rdrs/RDR-031-focused-agent-runs.md) — Focused Agent Runs architecture
