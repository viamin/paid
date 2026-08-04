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
