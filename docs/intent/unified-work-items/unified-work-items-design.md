---
parent: PAID
prefix: UNIFIED-WORK-ITEMS
---

# Low-Level Design: Unified Work Items

## Purpose

RDR-079 introduces a provider-neutral boundary for work tracked outside the
existing GitHub Issue shape. The boundary lets orchestration identify one item
without conflating provider, resource, and provider-local identifier, while
preserving the GitHub issue interface used by existing automation.

## Domain contract

`Automation::Providers::Data::WorkItemIdentity` is the stable key: `provider`,
`resource`, `external_id`, and presentation-only `display_id`. A work item has
normalized title, body, lifecycle, author, labels, timestamps, and URL, plus
typed assignments, comments, relations, attachments, and pull-request links.

Assignments record their principal, provenance (`:provider` or a future Paid
authority), and whether a local override applies. Lifecycle records both the
normalized state and provider value through `LifecycleMapping`; an ambiguous
mapping is represented by its conflict instead of being silently selected.
Provider-only attributes stay in `provider_extensions`; the received payload is
retained in `raw_payload` for audit and later provider evolution. Consumers
must use normalized fields and typed values, never infer policy from either
payload bag.

`Data::Issue` and the existing `fetch_issue`/`list_issues` methods remain the
GitHub compatibility contract. `fetch_work_item` and `list_work_items` are new
provider-neutral entry points. The GitHub implementation retains GitHub's raw
payload and typed extensions when serving the richer shape.

## Rollout

All new unified-work-item runtime entry points are guarded by
`FeatureFlags[:unified_work_items]`. The flag is default-off and is evaluated
for the project. With it disabled, callers receive a feature-disabled error and
the existing GitHub Issue behavior remains unchanged. Future provider reads,
assignment, and lifecycle operations must use this same guard before they are
exposed.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Add a parallel rich work-item snapshot | Mutate `Data::Issue` in place | Existing issue consumers construct and depend on the narrow shape; a parallel contract enables staged providers without breaking GitHub behavior. |
| Preserve raw payload beside typed extensions | Normalize every provider field | Raw retention supports audit and later mapping changes, while typed extensions prevent core policy from parsing provider blobs. |
| Default-off feature flag | Immediate replacement of GitHub reads | Provider-neutral reads have no established production semantics yet; opt-in bounds rollout without changing legacy behavior. |
