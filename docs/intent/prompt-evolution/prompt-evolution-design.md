---
parent: PAID
prefix: PROMPT-EVOLUTION
---

# Low-Level Design: Prompt Evolution

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-009](../../rdrs/RDR-009-prompt-evolution.md). This LLD documents the
> shipped prompt-version mutation, review, and live-assignment paths.

## Purpose

Paid treats prompts as versioned data that can be measured, mutated, reviewed,
and assigned at runtime. The implemented design has two distinct paths:

1. **offline evolution** — generate and persist new prompt versions from prior
   run outcomes; and
2. **live runtime assignment** — attach the active or assigned prompt version
   to an agent run so quality data stays attributable to a concrete version.

## Evolution Path

`Workflows::PromptEvolutionWorkflow` coordinates the evolution pass:

- sample recent runs,
- generate mutations,
- persist variant prompt versions,
- and create the A/B test that will gather live outcome data.

The workflow exits early with `no_candidates` or `no_mutations` when there is
not enough signal to continue.

## Variant Persistence and Review Gates

`PromptEvolution::CreateVariants` persists each mutation as a pending
`PromptVersion` with evolution provenance and parent-version lineage.

- If `prompt.requires_review?` is true, the new variants remain pending review
  and `current_version` is unchanged.
- If `prompt.requires_review?` is false, the first variant is auto-approved and
  promoted to `current_version`.

When auto-promotion activates a new variant for a paused project, Paid also
auto-resumes the project from the quality pause.

## Runtime Assignment

`Activities::RunAgentActivity` assigns running goal-wrapper A/B tests before
rendering the effective prompt for issue-goal, review-goal, and enhance-issue
runs. The assigned prompt version is stored on `agent_run.prompt_version` so
subsequent metrics and outcome analysis trace back to the concrete variant that
actually ran.

## Accepted Divergence

The runtime assignment path is currently strongest for goal-wrapper prompts in
`RunAgentActivity`. Some direct prompt-building paths still resolve the current
prompt version without live A/B assignment; this is an accepted current-state
boundary, not a contradiction of the versioned prompt model.

## References

- `app/services/prompt_evolution/create_variants.rb`
- `app/temporal/activities/run_agent_activity.rb`
- `app/temporal/workflows/prompt_evolution_workflow.rb`
