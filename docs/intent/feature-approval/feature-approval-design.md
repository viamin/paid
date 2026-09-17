---
parent: PAID
prefix: FEATURE-APPROVAL
---

# Low-Level Design: Feature Approval — Operating Mode & Onboarding

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the human-led feature operating mode from
> [RDR-066](../../rdrs/RDR-066-feature-intent-approval-lifecycle.md): the
> named project setting, its configuration profile, and the onboarding
> posture proposal.

## Purpose

RDR-066 shifts human attention to discovery, design, and decisions: once a
human approves a complete feature design, Paid may execute the whole feature
tree within that approved scope. The operating mode is the posture switch
that makes a project run that workflow for new features.

This slice (issue #3872) ships the mode setting, the named configuration
profile, and the onboarding default. The Feature Intent record, approval
lifecycle, Inbox approval actions, and the issue-tree hold/release arrive
with the wiring issues of the RDR-066 epic and will extend this segment.

## Design

### Operating-mode setting

- `projects.operating_mode` enum: `standard` (default) or
  `human_led_feature_factory` (`Project::OPERATING_MODES`).
- The column is the RDR-066 rollout-guard **config gate**: it ships default
  `standard`, so existing projects are never silently enrolled and nothing
  is paused on migration. No Flipper flag is involved — the guard is the
  named setting itself, exactly as the RDR's Rollout Guard specifies.
- The mode is a posture lever in the RDR-044 configuration-profile field
  set (`operating_mode` and `tdd_mode` descriptors), so the drift guards
  require every profile to declare an explicit value and existing profiles
  declare `standard` (opt-in only).

### Named profile

- `Configuration::Profiles::HumanLedFeatureFactory` is registered in the
  curated registry and targets `operating_mode:
  "human_led_feature_factory"`.
- Suggested test-review posture: `tdd_mode: "non_strict"`.
- Auto-merge stays `off` by default; the profile declares clarifying
  questions for `auto_merge_mode` and `tdd_mode` so the owner explicitly
  chooses both — auto-merge and strict human TDD remain independent
  selections, per RDR-066's operating-mode decision.

### Onboarding proposal

- The `configure_defaults` onboarding step proposes the
  `human_led_feature_factory` posture for the account's first project with
  a reviewable settings plan rendered from `Configuration::Profiles::Planner`
  (deterministic before/after diff) before any write executes.
- Applying happens only on explicit acceptance, through
  `Configuration::Profiles::Applier` (one audited
  `configuration_profile.applied` activity event), honoring the operator's
  auto-merge and TDD selections.
- Declining leaves the project on `standard` defaults.

### Disabling the mode

- Mode changes are settings-only writes. Disabling
  `human_led_feature_factory` (direct edit or applying another profile)
  never enqueues, releases, or mutates issue/run state — held feature work
  requires an explicit migration decision (RDR-066 rollback posture), and
  when the release hold ships it must keep honoring this boundary.

## What this is not

- **Not an auto-merge or TDD policy change.** The profile suggests a
  posture; the owner's explicit choices win, and other profiles keep
  `standard` mode with their existing automation posture.
- **Not the feature-approval workflow itself.** Approval records, Inbox
  actions, and the issue-tree hold are the epic's wiring issues; until they
  land, the mode is a recorded posture without enforcement machinery.
