---
parent: PAID
prefix: HEALTH-CHECKS
---

# Low-Level Design: Configuration Health Checks

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> covers the advisory configuration health-check system that evaluates Project,
> Runner, and User settings together, caches the resulting findings per
> project, renders them on a dedicated project health page, and mirrors those
> cached findings into auto-resolving in-app notifications.

## Purpose

Paid already validates many individual configuration fields at save time, but
 several operational failures are caused by otherwise-valid combinations across
 scopes: a project can enable auto-merge without an owner reviewer, or a
 runner can remain pinned to a model the provider registry has deprecated.

The configuration health-check system is the read-only advisory layer over that
live state. It does not block saves or mutate configuration. It computes a
uniform `HealthChecks::Result` from registered checks, persists that result in
`Rails.cache`, and exposes the result in two operator-facing surfaces:

- the project-scoped `/projects/:id/health` page
- auto-resolving `Notification` records generated from the cached findings

## Shipped Behavior

The implementation under `app/services/health_checks/` is composed of immutable
value objects (`Finding`, `Result`), an abstract `Check`, a `Registry`, an
isolating `Coordinator`, and a `Cache`.

- `HealthChecks::Coordinator.call(scope: :project, subject: project, include_network: ...)`
  runs the registered project checks on the project itself, the registered
  runner checks on `project.effective_owner.runners.kept_only.for_agent_runs`,
  and the registered user checks on `project.effective_owner`.
- Each raising check is contained and converted into an internal-error finding
  rather than aborting the entire run.
- `AccountHealthCheckSweepJob` is the source of truth. It recomputes each
  project's cached result daily on the `:maintenance` queue.
- `ProjectHealthCheckJob` recomputes one project's cached result on demand when
  the operator clicks "Re-run checks" on the health page.
- `Projects::HealthCheckController#show` renders the cached result only; the
  page does not run checks inline.

## Notification Sync

`HealthChecks::Notifications::RuleAdapter` is the bridge from cached findings
to the existing notification pipeline.

- After each cache refresh, the adapter reads the cached `Result` for that
  project and publishes one unresolved `Notification` per current finding.
- Every notification deep-links back to the project health page so the operator
  can see the full grouped result in one place.
- Notification `source` values are prefixed per project and include a stable
  fingerprint of the finding metadata. This preserves multiple active
  notifications when a single check emits more than one finding for the same
  subject and code, such as multiple deprecated model tiers on one runner.
- When a finding disappears from the cached result, the adapter resolves the
  stale notification on the next sync without manual dismissal.

## Current Catalog

The current shipped registry contains:

- Project checks: `AutoMergeWithoutOwner`, `ReviewWithoutBot`,
  `ReviewBotNotInstalled`, `EmptyAllowlist`, `MissingGitHubCredential`,
  `SensitiveDataFreeModel`
- Runner checks: `DeprecatedModel`
- User checks: `NoAgentRunners`, `InvalidFallbackChain`,
  `MissingDefaultRunner`

## What this is not

- **Not a schema feature.** The implementation uses existing tables plus
  `Rails.cache`; it does not add persistence tables for findings.
- **Not a blocking validator.** Findings are advisory; they surface operator
  risk and broken combinations without preventing saves.
- **Not a live request-time network probe.** Network-backed checks run in the
  background recomputation path only, never synchronously in the health page
  request.
