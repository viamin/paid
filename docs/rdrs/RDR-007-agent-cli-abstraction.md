# RDR-007: Agent CLI Abstraction (agent-harness adoption)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Provider unit tests, integration tests for each agent type

## Decision

Adopt the existing **`agent-harness`** gem as Paid's CLI agent abstraction layer. Paid integrates with the gem's production interface and does not implement its own adapter layer.

## Why This Decision

- **Unified interface** for heterogeneous CLIs (Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, Kilocode).
- **Operational resilience** via orchestration (fallbacks, circuit breakers, rate limits, health monitoring).
- **Consistent response shape** for metrics and auditing.
- **Typed errors** for consistent workflow handling.
- **Production-proven** interface already extracted from aidp patterns.

## Scope and Boundaries

**Paid responsibilities:**

- Configure providers and orchestration using `AgentHarness.configure`.
- Call `AgentHarness.send_message` for orchestrated execution.
- Record metrics from `AgentHarness::Response` (output, exit_code, duration, provider, model, tokens).
- Handle typed exceptions (e.g., `RateLimitError`, `TimeoutError`, `NoProvidersAvailableError`).
- Keep firewall allowlist aligned with provider `firewall_requirements`.
- Mount instruction files defined by `instruction_file_paths` when needed.

**agent-harness responsibilities:**

- Provider contract (`AgentHarness::Providers::Adapter`).
- Provider registry + aliasing (`Providers::Registry`).
- Orchestration (`Orchestration::Conductor`, circuit breakers, rate limiting, health monitoring, retries).
- Token tracking (`AgentHarness::TokenTracker`).
- Error taxonomy (`AgentHarness::ErrorTaxonomy`) and typed errors.

**Out of scope:**

- API-only LLM calls for planning/evaluation (handled by ruby-llm directly in Paid).

## Integration Requirements

- **CLI-first** execution inside containers.
- **Provider availability checks** via `Providers::Registry.instance.available`.
- **Metrics collection** from `Response` and token tracker callbacks.
- **Firewall alignment** with provider `firewall_requirements`.
- **Instruction files** wired from provider `instruction_file_paths`.

## Alternatives Considered

1. **Direct CLI calls in workflows**
   - Rejected due to duplicated parsing/handling and higher maintenance cost.

2. **API-only approach (ruby-llm only)**
   - Rejected because CLI agents provide better coding features and parity.

3. **aidp provider abstraction directly**
   - Rejected because agent-harness is already the extracted, production interface.

## Consequences

**Positive:**

- Standardized CLI execution and metrics across agents.
- Centralized resilience policies.
- Easier onboarding of new providers.

**Negative:**

- Dependency on gem API stability.
- CLI output parsing remains fragile across versions.

## Risks and Mitigations

- **CLI output changes** → Pin CLI versions in container image; add parsing fallbacks.
- **Provider mismatch** → Validate availability and fail fast with typed errors.
- **Firewall drift** → Keep allowlist synced to provider `firewall_requirements`.

## Validation

- Unit tests per provider (mocked CLI execution).
- Integration tests against real CLIs in container.
- Error classification tests for common failure modes.
- Token tracking tests with sample outputs.

## References

- Paid `AGENT_SYSTEM.md`
- `agent-harness` gem source and README
- aidp provider abstraction patterns
