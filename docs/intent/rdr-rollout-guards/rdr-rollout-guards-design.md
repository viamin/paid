---
parent: PAID
prefix: RDR-ROLLOUT-GUARD
---

# Low-Level Design: RDR Rollout Guards

> Companion to the RDR workflow in `docs/rdrs/README.md` and the `create_feature`
> goal from RDR-053.

## Purpose

Paid often ships releases while an accepted RDR is only partly implemented. The
safe default is that runtime behavior from an incomplete RDR stays behind an
explicit guard until the closeout audit says the behavior is complete and can be
made default.

## Contract

Every new RDR includes a `## Rollout Guard` section. For runtime changes, the
section names the feature flag or config gate, its default state, rollback
action, and cleanup criteria. Non-runtime work uses `docs-only`,
`migration-only`, or `none required` with a short justification.

`Features::RdrContract` enforces the section for `create_feature` docs-only PRs.
`Prompts::BuildForCreateFeature` tells RDR authors to fill it in, and
`PromptAssembly::Sections::RdrRolloutGuard` reminds implementation agents to
read and preserve it before changing runtime behavior.
