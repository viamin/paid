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
section names the feature flag or config gate, its default state, enablement
surface, rollback action, and cleanup criteria. Feature-flag guards also name
the implementation issue that adds the key to `FeatureFlags::DEFINITIONS` and
wires the runtime decision through `FeatureFlags.enabled?(:flag_name, project:)`.
Non-runtime work uses `docs-only`, `migration-only`, or `none required` with a
short justification.

## Project-type conditioning

`FeatureFlags` is a Paid-specific Ruby API, not a Ruby or Rails convention.
Demanding `FeatureFlags::DEFINITIONS` / `FeatureFlags.enabled?` artifacts from
a repository without that API would force porting a foreign flag system into
the target project (#4172). `Projects::DetectRepoProfile` records the pattern
only when `app/services/feature_flags.rb` defines the `FeatureFlags` class,
`DEFINITIONS`, and `enabled?`. `Features::FlagGuardPattern` requires that scan
evidence before applying the Paid wiring. A Ruby, Rails, or undetected project
without that evidence uses a repository-native guard and can never be blocked
on artifacts it cannot produce.

`Features::RdrContract` enforces the section for `create_feature` docs-only PRs;
on a project without the detected API it drops the two `FeatureFlags::` wiring
checks and keeps the language-agnostic enablement-surface requirement.
`Prompts::BuildForCreateFeature` tells RDR authors to fill the section in —
naming the Paid flag system only where detected, or the repository's own
flag/config mechanism elsewhere — and
`PromptAssembly::Sections::RdrRolloutGuard` reminds implementation agents to
read and preserve it before changing runtime behavior. The guard trigger reads
the issue title, body, and any trusted/admitted collaborator comments
(mirroring `PromptAssembly::Trust.comment_trusted?`); a bare reference inside
an untrusted comment is ignored so prompt-injected bodies cannot disable the
guard.
