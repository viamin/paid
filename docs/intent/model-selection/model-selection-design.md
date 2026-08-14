---
parent: PAID
prefix: MODEL-SELECTION
---

# Low-Level Design: Model Selection

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-008](../../rdrs/RDR-008-model-selection.md). This LLD documents the
> shipped hybrid selector, its persistence contract, and its tier-aware
> candidate routing.

## Purpose

Paid chooses a model per run, but the choice must be both adaptive and auditable.
The shipped design combines deterministic override paths, an LLM meta-agent,
and a rules fallback while persisting every accepted choice as data on the run.

## Selection Flow

`Models::Select` is the orchestration entry point. It applies selectors in this
order:

1. explicit project-required model,
2. quality-recovery escalation,
3. project preferred models,
4. tenant-level model preference,
5. meta-agent selection,
6. rules-based fallback.

If no compatible selection survives policy and runner-compatibility checks,
Paid records a no-selection decision log instead of persisting an invalid
`ModelSelection`.

## Persistence Contract

Accepted selections are stored in `model_selections` and linked to the run. The
stored record includes:

- the chosen `llm_model` when one is available,
- `selector_type`,
- ranked `candidates`,
- the final `tier`,
- selection duration,
- and any quality-recovery escalation metadata.

This record is the run-level audit object for model choice.

## Candidate Routing

### Meta-agent

`Models::MetaAgentSelector` uses `AgentHarness.send_message` to pick from the
currently eligible candidate pool. The candidate pool is constrained by:

- runner/provider compatibility,
- project exclusions,
- and the initial tier derived from the rules-based complexity estimate.

Codex subscription runners also apply Paid's compatibility denylist for
catalog models observed to be unavailable to ChatGPT Codex accounts. This
guard runs before default tier selection so a newly synced or manually seeded
OpenAI model cannot become the highest-scored default merely because it exists
in the catalog.

When only one candidate remains, the selector skips the LLM round trip and
returns that candidate directly.

### Rules fallback

`Models::RulesBasedSelector` computes a complexity score from run context,
maps that score to a tier via `Models::TierForComplexity`, and ranks
compatible candidates within that tier. If the tier has no active candidates,
it falls back to the broader compatible pool so missing tier data does not
leave the run unselectable.

## Accepted Divergence

RDR-008's older raw RubyLLM examples are superseded. The production selector
uses `agent_harness` for meta-agent calls. Selection-time affordability
filtering is not a hard prerequisite of the current design; budget and policy
signals are logged and enforced elsewhere in the run lifecycle.

## References

- `app/services/models/select.rb`
- `app/services/models/meta_agent_selector.rb`
- `app/services/models/rules_based_selector.rb`
- `app/models/model_selection.rb`
