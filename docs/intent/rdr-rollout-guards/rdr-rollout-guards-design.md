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

`FeatureFlags` is a Ruby class in the Rails codebase pattern this design came
from. Demanding `FeatureFlags::DEFINITIONS` / `FeatureFlags.enabled?` artifacts
from a non-Ruby repository (GDScript, Python, Rust, ...) would force porting a
foreign flag system into the target project (#4172). `Features::FlagGuardPattern`
therefore decides applicability from the project's detected languages: the
Rails wiring is required only where Ruby is among them, and a project with no
detected language is treated as non-Ruby so an undetected greenfield repo can
never be blocked on artifacts it cannot produce.

`Features::RdrContract` enforces the section for `create_feature` docs-only PRs;
on non-Ruby projects it drops the two `FeatureFlags::` wiring checks and keeps
the language-agnostic enablement-surface requirement. `Prompts::BuildForCreateFeature`
tells RDR authors to fill the section in — naming the paid flag system on Ruby
projects, or the repository's own flag/config mechanism elsewhere — and
`PromptAssembly::Sections::RdrRolloutGuard` reminds implementation agents to
read and preserve it before changing runtime behavior. The guard trigger reads
the issue title, body, and any trusted/admitted collaborator comments
(mirroring `PromptAssembly::Trust.comment_trusted?`); a bare reference inside
an untrusted comment is ignored so prompt-injected bodies cannot disable the
guard.
