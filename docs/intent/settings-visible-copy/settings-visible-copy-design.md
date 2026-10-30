---
parent: root
prefix: SETTINGS-COPY
---

# Design: Settings Visible Copy

Settings present configuration choices in terms of their behavior and
consequences. Internal decision-record identifiers, issue numbers, and
repository-specific example paths remain implementation documentation; they
are not operator-facing copy.

## Scope

This segment owns the visible copy for project screenshot verification, TDD
mode, existing design-document input, tenant chat controls, and feature-flag
metadata rendered in tenant configuration. It does not change setting keys,
form values, feature-flag names, rollout behavior, or runtime policy.

## Verification plan

| Acceptance criterion | Evidence |
| --- | --- |
| Project and account settings render no Paid-owned RDR identifier or the old RDR path example | Request spec renders the project edit/show and tenant configuration pages, rejects RDR identifiers, and checks the generic design-document example. |
| Keys, values, flag names, and behavior remain unchanged | Focused request spec renders the existing controls; review the diff for copy-only changes. |
| Visible project, tenant, and feature-flag description copy is covered | The same request spec uses the real `FeatureFlags::DEFINITIONS` registry and asserts visible replacement copy. |
