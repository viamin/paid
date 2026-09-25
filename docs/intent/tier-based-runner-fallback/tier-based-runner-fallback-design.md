---
parent: PAID
prefix: RUNNER-FALLBACK
---

# Low-Level Design: Tier-Based Runner Fallback

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-034](../../rdrs/RDR-034-tier-based-runner-fallback.md). This LLD
> documents the shipped tier-first runner fallback contract.

## Purpose

Runner fallback must survive primary-runner failures even when alternate
runners execute different concrete models. The implemented contract binds the
run to a tier and resolves the concrete model per runner attempt.

## Run-Level Contract

`ModelSelection#tier` is the durable run-level routing contract. A concrete
`llm_model_id` may still be present for the first attempt or for analytics, but
fallback eligibility is driven by tier support rather than by matching a single
concrete model across every runner.

## Fallback Routing

`Activities::RunAgentActivity` filters candidate runners by tier support,
resolves the concrete model for each attempt via `Runners::ResolveTierModel`,
and records the resolved attempt metadata on `agent_run.runners_attempted`.

The resolved model is passed explicitly to both preflight and execution through
agent-harness, including subscription-authenticated runners. Authentication
isolation remains in place; container defaults must not override the resolved
model. When a run has no model-selection record, an explicitly configured
mid-tier runner model supplies the execution default through the same
compatibility checks and attempt logging. Recovery must reject inactive catalog
models and preserve project model exclusions, required-model settings, and
provider routing restrictions before any provider execution.

Subscription runner health tests use the explicit mid-tier model when configured,
with the same compatibility resolution and credential isolation. Invalid model
configuration is surfaced instead of falling back to a different CLI default.

## Durable Model Compatibility Recovery

An explicit provider rejection of a model for the configured authentication
starts bounded recovery on the same runner, with the same credentials. The
harness owns rejection classification and live model discovery inside the
execution environment. Static catalog compatibility is advisory when the
provider supports live verification; it must not prevent verification of a
configured subscription model. Actual successful preflight is the evidence
required to remember a replacement.

Paid filters discovered candidates through project required-model, exclusion,
provider-routing, and operator model-disable policies. It prefers suitable
same-tier alternatives, then permits another tier if necessary. Selection uses
the existing model selector with an explicitly bounded candidate pool; provider
recommendation supplies the fallback when selection cannot run. Discovery alone
does not establish compatibility. At most three replacement preflights per
runner per run are allowed, within the run's execution time budget. A further
failure falls through to normal runner fallback, with a visible diagnostic.

Verified replacements and actual rejections are persisted for the runner and
its auth/configuration identity, independently of catalog refreshes and process
lifetime. Replacements override the rejected tier mapping for future runs,
including when a replacement crosses tiers. They have no time-based expiry and
are reconsidered after a new model rejection or an explicit configuration/auth
change. Project restrictions are checked again on every use. Concurrent recovery
must not overwrite a newer configuration or a newer recovery decision.

Recovery never changes authentication mode or payment mode, reactivates an
operator-disabled model, or treats expired authentication, rate limits, transport
errors, or agent prose as a model rejection. An unsuccessful preflight cannot
become the durable selected model. Run attempts and logs identify rejected and
verified models and any tier change. A rejection during execution may retry
with the verified replacement; completed runs are never replayed automatically.

Each attempt can capture:

- the attempted runner,
- `resolved_model_id`,
- `resolved_provider_id`,
- resolution source,
- success/failure outcome,
- and any diagnostics.

This keeps fallback honest: analytics can see what actually ran, not only what
the primary selection preferred.

## Accepted Divergence

RDR-034 described optional `selector_type: tier_only` and `model_pin` escape
hatches that were not implemented. The production path instead keeps the tier
as the durable contract while continuing to allow informative concrete-model
metadata where available.

## References

- `app/temporal/activities/run_agent_activity.rb`
- `app/models/model_selection.rb`
- `app/services/runners/resolve_tier_model.rb`
