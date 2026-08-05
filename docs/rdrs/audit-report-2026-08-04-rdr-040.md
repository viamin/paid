# RDR-040 Closeout Audit

## Metadata

- **RDR**: RDR-040 Runner Model Compatibility Contracts
- **Audit date**: 2026-08-04
- **Audit issue**: #3171
- **Original implementation issue**: #2600
- **Outcome**: Implemented

## Scope

This audit verified the four remaining partial-status claims left on RDR-040:

1. Compatibility enforcement in `Models::Select` override paths.
2. Full compatibility usage during fallback ordering.
3. Provider runtime propagation into compatibility checks where concrete runner runtime matters.
4. Proactive drift reporting for active model rows versus runner contracts.

## Findings

### 1. `Models::Select` override paths enforce runner compatibility

Confirmed.

- `Models::Select` runs explicit overrides through `override_compatible_or_nil`, which checks `runner_compatibility_result` whenever the run is already bound to a concrete runner.
- Required-model overrides surface an explicit incompatibility sentinel so the run records a `no_selection` outcome with the rejected model metadata instead of silently persisting a broken selection.
- Preferred-model and tenant-model override branches also guard on `runner_compatible?` before returning an override selection.

Evidence:

- `app/services/models/select.rb`
- `spec/services/models/select_spec.rb`
  - incompatible required-model override on a bound runner
  - incompatible preferred-model override on a bound runner
  - incompatible tenant-preferred override on a bound runner

### 2. Fallback ordering uses the full compatibility contract

Confirmed.

- `AgentRuns::RunnerResolver` computes an override-driven compatibility fallback before final runner selection.
- That fallback checks every runnable candidate with `Runners::ModelCompatibility.call`, not a provider-only shortcut.
- When no compatible runner exists, the resolver emits `agent_execution.no_compatible_runner_for_override` so the mismatch is visible in logs.

Evidence:

- `app/services/agent_runs/runner_resolver.rb`
- `spec/services/agent_runs/runner_resolver_spec.rb`
  - picks a compatible runner for a required model
  - warns when no compatible runner exists
  - respects tenant preference lookups only when `effective_runner` is known

### 3. Provider runtime is passed into compatibility checks where needed

Confirmed.

- `Runners::ModelCompatibility` forwards `provider_runtime` to `AgentHarness.model_compatibility` when the installed harness version accepts the `runtime:` keyword.
- `Models::Select` uses the bound runner's runtime when evaluating override and scoped candidate compatibility.
- `AgentRuns::RunnerResolver` uses the candidate runner's runtime when compatibility-ordering the fallback chain.
- `Runners::ResolveTierModel` remains the late-binding enforcement point for tier-to-model resolution on the resolved runner.

Evidence:

- `app/services/runners/model_compatibility.rb`
- `app/services/agent_runs/runner_resolver.rb`
- `spec/services/runners/model_compatibility_spec.rb`
- `spec/services/runners/test_agent_spec.rb`

### 4. Proactive drift reporting exists for active model rows vs runner contracts

Confirmed.

- `Models::DetectContractDrift` scans active `LlmModel` rows against the current runner contracts and groups only hard incompatibilities.
- `ModelHealthCheckJob` includes that detector and `Models::FileModelHealthIssue` incorporates the findings into the filed health issue.
- This is proactive reporting; `Models::DetectBrokenRunnerModels` remains the reactive backstop for runtime failures.

Evidence:

- `app/services/models/detect_contract_drift.rb`
- `app/jobs/model_health_check_job.rb`
- `app/services/models/file_model_health_issue.rb`
- `spec/services/models/detect_contract_drift_spec.rb`

## Conclusion

RDR-040 no longer needs a partial status.

The remaining bullets listed in the RDR are already implemented and covered by code paths plus regression specs. No additional follow-up issue is required from this closeout. The stale dependency on #2600 as pending work should be removed; #2600 remains historical implementation context only.
