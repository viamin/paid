---
parent: PAID
prefix: UNIFIED-WORK-ITEMS
---

# Low-Level Design: Unified Work Items

Implements RDR-079 Phase 1.

## Purpose

Paid accepts work from trackers with different identifiers, lifecycle names,
assignment semantics, and pull-request representations. The provider-neutral
contract must preserve those differences without making orchestration depend on
one provider's payload shape.

## Contract

`Automation::Providers::Data::WorkItem` is the Phase 1 immutable snapshot.
Its `Identity` has provider, resource type, resource ID, and container ID so a
provider-local key is never mistaken for a globally unique identifier. The
normalized fields carry title, body, author, labels, timestamps, URL, and a
normalized lifecycle. `raw_payload` retains the source response for audit and
future provider-specific interpretation; it is not a policy input.

Provider-specific fields are represented by typed extension records. The base
`Extension` carries an explicit provider and type discriminator; supported
providers can expose a typed record such as `GithubExtension` without changing
the normalized contract.

Comments, relations, attachments, assignments, and pull-request links are
separate typed collections. An assignment records its provider, Paid, or
inherited provenance and any explicit Paid override actor and time. A
`Lifecycle` records the normalized state, native state, mapping outcome, and a
structured conflict where a requested and observed state disagree. Work item to
pull request links use an explicit relationship and a pull-request identity;
they are not inferred from title, body, or numeric coincidence.

## GitHub compatibility

Existing callers continue to receive `Data::Issue` from
`Github::WorkItemProvider`. The legacy snapshot now retains the raw GitHub
response and exposes `#to_work_item`; conversion preserves the established
GitHub issue fields while offering the richer unified representation. This
phase does not change issue selection, lifecycle writes, or existing GitHub
automation behavior.

## Rollout guard

`unified_work_items` is a default-off feature flag defined in `FeatureFlags`.
New unified-work-item runtime surfaces must read
`Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project)`, which
uses `FeatureFlags.enabled?(:unified_work_items, project:)`. This evaluates the
project actor while honoring an account tenant-setting override. Existing
GitHub issue behavior remains outside this new guard.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Add a parallel immutable contract | Replace `Data::Issue` immediately | A compatibility adapter avoids breaking current GitHub consumers while providers migrate independently. |
| Preserve raw payloads | Normalize only | Normalization necessarily loses provider detail needed for audit, repair, and future mappings. |
| Record lifecycle conflicts | Silently pick native or normalized state | A visible conflict prevents a failed mapping from looking like a successful state transition. |
