# RDR-040: Runner Model Compatibility Contracts

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Status**: Draft
- **Date**: 2026-06-13
- **Priority**: P1
- **Related RDRs**: RDR-007 (Agent CLI Abstraction), RDR-008 (Model Selection Strategy), RDR-034 (Tier-Based Runner Fallback), RDR-038 (Free Models Catalog and Runner)

## Problem Statement

Paid currently treats model selection and runner execution compatibility as loosely coupled concerns. The model catalog can mark an OpenAI model active, while the Codex CLI installed in the Paid agent image may not support that model. A recent Codex fallback failure exposed this gap: a subscription-auth Codex container inherited a host `~/.codex/config.toml` default of `gpt-5.5`, but the agent image's pinned Codex CLI rejected that model before the agent could start.

The immediate fix pins subscription-auth Codex containers to Paid's active Codex-compatible model instead of inheriting host model defaults. That is a guardrail, not a full architecture. Paid needs a durable compatibility contract so unsupported models are rejected before scheduling and before runner fallback burns capacity.

## Context

### Current Architecture

- Paid owns `LlmModel` records, including active state, provider, cost, capability score, category, and `low` / `mid` / `high` tier labels.
- Paid's selectors choose a desired model or tier based on task complexity, project policy, budget, quality recovery, and runner settings.
- `agent-harness` owns provider CLI command construction, runtime preparation, parsing, error classification, installation contracts, and supported CLI version ranges.
- Agent images install runner CLIs from `agent-harness` installation contracts. For Codex, the installed harness version pins CLI support to a narrow version range.
- Direct-outbound runners such as OpenCode and Pi have additional model constraints because model IDs are scoped to a specific upstream provider configuration.

### Observed Failure Mode

Agent run `26774` failed before real work started:

1. The first fallback runner timed out during smoke preflight.
2. Codex failed preflight with "The 'gpt-5.5' model requires a newer version of Codex."
3. Claude then exited with `137`, exhausting the fallback chain.

The important lesson is not only that the container inherited the wrong host config. The deeper issue is that model use was not validated against the actual runner executable and auth mode before execution.

## Recommendation

Introduce a two-layer model compatibility contract:

1. **`agent-harness` owns runner capability and compatibility facts.**
   - Supported CLI version requirement.
   - Auth modes supported by the provider.
   - Concrete supported model IDs when the provider can know them.
   - Explicit unsupported model IDs or patterns when support is version-dependent.
   - A runtime validation API such as `supports_model?(model_id:, auth_type:, cli_version:, runtime:)`.
   - Optional model aliases or migrations when the provider CLI has first-class migration behavior.

2. **Paid owns tier policy and model routing.**
   - `low`, `mid`, and `high` remain Paid product concepts tied to cost, quality, task complexity, budgets, data policy, and fallback behavior.
   - Paid maps tiers to model candidates from `LlmModel`.
   - Paid filters and validates those candidates through the runner compatibility contract before saving runner settings, selecting defaults, or starting an agent run.

This keeps the boundary clean: `agent-harness` says what a runner can execute; Paid decides what should be used for a customer task.

## Proposed Design

### Compatibility API

Add an `agent-harness` provider API with a shape like:

```ruby
compatibility = AgentHarness.provider(:codex).model_compatibility(
  model_id: "gpt-5.1",
  auth_type: :subscription,
  cli_version: "0.122.0",
  runtime: provider_runtime
)
```

Return a structured result:

```ruby
{
  supported: true,
  reason: nil,
  replacement_model_id: nil,
  source: "codex_cli_contract",
  cli_requirement: ">= 0.122.0, < 0.123.0"
}
```

For unsupported cases:

```ruby
{
  supported: false,
  reason: "model requires a newer Codex CLI",
  replacement_model_id: "gpt-5.1",
  source: "codex_cli_contract",
  cli_requirement: ">= 0.122.0, < 0.123.0"
}
```

### Paid Services

Add a Paid-side service, tentatively `Runners::ModelCompatibility`, responsible for:

- Resolving the runner's harness provider.
- Passing runner key, auth type, configured runtime, and installed CLI contract to `agent-harness`.
- Applying compatibility filtering to `Runners::DefaultTierModelIds`.
- Validating runner `tier_models` and project/tenant model overrides.
- Producing user-facing failure messages when a configured model cannot run.

Update model selection and runner resolution so compatibility is checked before preflight:

- `Models::Select` should select from compatible candidates for the run's runner when a concrete runner is known.
- `Runners::ResolveTierModel` should reject or skip tier mappings unsupported by the selected runner.
- `ProcessRunQueueJob` / late-binding work should consider runner compatibility when choosing a runnable runner.
- `Models::DetectBrokenRunnerModels` should become a backstop, not the first place the system learns a model is unsupported.

### User Experience

Unsupported configurations should surface in settings and run history:

- Runner settings should flag "Model unsupported by installed Codex CLI" rather than saving a broken mapping silently.
- Agent run logs should show "No compatible Codex model for mid tier" instead of generic "All runners exhausted" where possible.
- Dashboards should report compatibility drift between active `LlmModel` records and installed runner contracts.

## Alternatives Considered

### Alternative 1: Let `agent-harness` Own Tier Mapping

`agent-harness` would expose `low`, `mid`, and `high` models per provider, and Paid would consume those directly.

Rejected as the primary design. Tiers are product policy, not execution mechanics. Paid's tiers encode cost, task complexity, quality recovery, account policy, and routing trade-offs. Moving tier meaning into `agent-harness` would couple product decisions to CLI adapters and make cross-runner comparisons harder.

### Alternative 2: Keep Only Paid's `LlmModel` Catalog

Paid would continue selecting active provider models and rely on preflight failures to catch unsupported runner/model combinations.

Rejected. This preserves the current failure mode: user-visible agent runs burn queue time and fallback attempts before discovering that a model cannot execute.

### Alternative 3: Runtime `codex update`

Paid containers would self-update Codex at startup so newer host defaults are more likely to work.

Rejected for production runner execution. Runtime self-update bypasses the image build's audited install contract, weakens reproducibility, and can change command semantics, auth behavior, config parsing, or JSONL output without a matching `agent-harness` update.

### Alternative 4: Strip All Host Codex Model Settings Only

This is the current tactical fix. It prevents host defaults from poisoning container runs, but it does not validate Paid-selected models against runner support.

Accepted as a short-term guardrail, not the strategic solution.

## Trade-offs and Consequences

### Positive Consequences

- Unsupported model choices fail at configuration or scheduling time, not after a container is provisioned.
- Runner fallback becomes more reliable because fallback candidates are filtered by actual execution capability.
- Product tier policy remains in Paid, where budget, quality, and customer policy context exists.
- `agent-harness` remains the single source of truth for CLI-specific behavior and version compatibility.

### Negative Consequences

- Paid and `agent-harness` need a richer API contract and coordinated releases.
- Some providers cannot know all model availability statically because account entitlements vary.
- Compatibility checks may require a mix of static contracts and smoke/runtime validation.
- Existing `LlmModel` rows may need migration or drift reports when they are active but incompatible with installed runner contracts.

### Risks and Mitigations

- **Risk**: Compatibility metadata becomes stale.
  - **Mitigation**: Run model health checks that compare active Paid catalog entries against installed runner contracts and recent runtime errors.
- **Risk**: Tier semantics drift between Paid and provider metadata.
  - **Mitigation**: Keep tier definitions in Paid and treat provider tiers as optional hints only.
- **Risk**: Providers expose model support dynamically by account.
  - **Mitigation**: Model compatibility API should support "unknown" and "requires runtime check" outcomes, not only boolean supported/unsupported.
- **Risk**: Fallback chains shrink when strict compatibility filtering is introduced.
  - **Mitigation**: Surface "no compatible runner" explicitly and continue investing in late-bound runner selection.

## Implementation Plan

1. Add `agent-harness` compatibility metadata for Codex.
   - Start with installed CLI version requirement and known unsupported/newer-model cases.
   - Expose structured compatibility results.

2. Add Paid `Runners::ModelCompatibility`.
   - Wrap harness compatibility in a Paid service.
   - Normalize runner key, auth mode, runtime, and selected model.

3. Filter default tier model mappings.
   - Update `Runners::DefaultTierModelIds` to choose the best active model per tier that is compatible with the target runner.
   - Preserve Paid's fallback behavior when a tier has no compatible model.

4. Validate configured tier mappings.
   - Reject runner `tier_models` that cannot run on the selected runner/auth mode.
   - Add remediation copy for users.

5. Apply compatibility before execution.
   - Update `Runners::ResolveTierModel` and run queue binding to skip incompatible runner/model pairs.
   - Prefer a compatible fallback runner over a preferred runner with an incompatible model.

6. Add observability.
   - Extend broken-runner model detection to file compatibility drift findings.
   - Add dashboard signals for active models unsupported by installed runner contracts.

## Validation

### Tests

- Codex subscription runner rejects a model requiring a newer CLI before container preflight.
- Codex subscription runner maps `mid` to the highest compatible active Paid model.
- Project-required model fails with a clear compatibility error when unsupported by the runner.
- Runner fallback skips incompatible runners and selects a compatible alternative.
- Direct-outbound runner tier models remain constrained to their configured provider/model pair.

### Operational Checks

- Agent image contract tests assert the installed Codex CLI satisfies the `agent-harness` requirement.
- Model health checks report active catalog models incompatible with installed runner contracts.
- Recent failure detector should show decreasing "requires newer version of Codex" occurrences after rollout.

## Decision

Proceed with the two-layer compatibility contract. Do not move tier ownership wholesale into `agent-harness`. Keep Paid responsible for tier policy and model routing; make `agent-harness` authoritative for runner execution compatibility.
