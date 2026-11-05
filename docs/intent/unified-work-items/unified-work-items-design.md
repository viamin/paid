---
parent: ../README.md
prefix: UNIFIED-WORK-ITEMS
specs: unified-work-items-specs.md
---

# Unified Work Items

Implements [RDR-079](../../rdrs/RDR-079-unified-tracker-work-items.md).

Tracker-specific APIs are adapted into `Automation::Providers::Data::WorkItem`.
Its `ProviderIdentity` prevents collisions between provider-local identifiers;
the typed extension and raw payload preserve facts that cannot safely be
normalized. Comments, relations, attachments, assignment provenance and local
overrides are represented explicitly. Lifecycle mappings carry both the native
state and a conflict when a provider state cannot be reconciled. Pull-request
links are explicit relationships rather than an inference from a shared number.

GitHub's existing `Data::Issue` remains the compatibility API. The richer
`fetch_work_item` API is an opt-in read surface guarded by
`unified_work_items`.
