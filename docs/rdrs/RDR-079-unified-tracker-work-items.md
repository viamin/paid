# RDR-079: Unified Tracker Work Items

## Status

Accepted

## Decision

Paid will represent external tracker resources through a provider-neutral work-item
contract. The contract has a stable provider/resource identity, normalized state,
typed provider extension, raw provider payload, comments, relations, attachments,
assignment provenance and overrides, lifecycle mapping/conflict information, and
explicit pull-request relationships.

The existing GitHub `Data::Issue` contract remains available during migration.
New rich work-item reads are guarded by the default-off `unified_work_items`
feature flag and may be enabled per project through `FeatureFlags`.

## Rollout Guard

`unified_work_items` is default-off. New unified work-item runtime entry points
must call `UnifiedWorkItems::Feature.ensure_enabled!`; existing GitHub issue
entry points retain their established behavior while the flag is disabled.
