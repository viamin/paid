---
parent: PAID
prefix: BUNDLE-OPT
---

# Low-Level Design: Bundle Outcome Optimization

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-015](../../rdrs/RDR-015-end-to-end-optimization.md). This LLD documents
> the shipped configuration-bundle optimizer and its accepted surrogate-model
> divergence.

## Purpose

Paid optimizes full run configurations as bundles instead of treating prompt,
model, and orchestration choices as isolated tuning knobs. The runtime selector
must choose between experiment variants while balancing expected outcome
improvement against uncertainty and exploration budgets.

## Candidate Ranking

`ConfigurationBundles::Optimizer` builds every valid active experiment
combination for the run, fingerprints each candidate bundle, scores it through
the surrogate model, and ranks candidates by expected improvement.

The selected result records:

- bundle definition and fingerprint,
- predicted objective and quality,
- uncertainty and sample count,
- selection mode (`exploitative` or `exploratory`),
- selection context (`task` or `project`),
- and the budget snapshot that justified the routing decision.

Exploration is gated by project/task exploration budgets and bootstrap rules.

## Surrogate Model

Production does not use the Gaussian Process surrogate originally described in
RDR-015. The accepted production surrogate is
`ConfigurationBundles::SurrogateOutcomeModel`, which:

- trains on historical bundle outcomes,
- filters matches by exact bundle identity context,
- uses weighted categorical similarity over the remaining features,
- blends sparse observations with a prior mean/weight,
- and returns both predicted outcome values and uncertainty.

This satisfies the optimizer's runtime need for mean + uncertainty without the
continuous-space assumptions of a GP.

## Accepted Divergence

The weighted similarity/prior surrogate is the production contract. The GP path
is retained only as a future direction for a denser, more continuous
configuration space.

## References

- `app/services/configuration_bundles/optimizer.rb`
- `app/services/configuration_bundles/surrogate_outcome_model.rb`
