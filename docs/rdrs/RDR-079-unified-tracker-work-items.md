# RDR-079: Unified Tracker Work Items

## Metadata

- **Date**: 2026-11-05
- **Status**: Draft
- **Type**: Architecture + External Integration
- **Related RDRs**: [RDR-012](RDR-012-github-integration.md) and [RDR-023](RDR-023-automation-modularization-architecture.md)
- **Related intent**: `docs/intent/unified-work-items/`
- **Tracking issue**: #4854
- **Implementation status**: Design proposal only; no runtime behavior changes in this RDR.

## Problem Statement

Adopt a provider-neutral persisted `WorkItem` record for GitHub and external
tracker tickets, beginning with Linear, while composing with the existing
tracker configuration, tracker adapter, and automation provider seams.

Paid currently uses GitHub-centered issue workflows. Users need a single,
trustworthy workflow and assignment boundary for GitHub and external-tracker
tickets without conflating tickets with pull-request review artifacts.

## Context

Paid already has two integration seams relevant to external trackers.
`TrackerConfiguration` owns the account, user, or project tracker
configuration, credential, and project mapping;
`IssueTrackers::Adapters::Linear` provides the Linear transport.
Separately, `Automation::Providers::Resolver` chooses a registered
`WorkItemProvider` for a project's provider type. A new unified model must not
copy Linear credentials or mappings into a second configuration path.

Tickets represent work to be done. Pull requests remain review artifacts and
must not acquire ticket lifecycle semantics.

## Research Findings

`TrackerConfiguration` already owns the Linear connection, integration
credential, configuration scope, and `project_mapping`. The adapter and
automation seams provide provider-specific transport and capability selection,
but neither supplies a provider-neutral persisted ticket identity or bounded
GitHub-to-unified migration path.

## Proposed Solution

`WorkItem` is the durable local identity and reconciliation record. It stores
provider/resource identity, normalized imported state, typed extensions, raw
payloads, assignment provenance, explicit overrides, and ticket-to-pull-request
relationships. It does not store a second provider credential or ticket-to-
project mapping.

The account's `TrackerConfiguration` remains authoritative for the Linear
connection, integration credential, configuration scope, and `project_mapping`.
`IssueTrackers::Adapters::Linear`, selected through `AdapterFactory`, remains
the provider transport for validation, synchronization reads, comments, status
writes, and PR links. Sync services use that adapter and upsert `WorkItem`
records by provider identity.

Automation continues to use `Automation::Providers::WorkItemProvider`. The
Linear work-item factory is registered with
`Automation::Providers::Resolver.register(:linear, work_item: ...)`; projects
that use Linear select it with `provider_type: :linear`. The factory resolves
the account's existing Linear configuration and operates on its local
`WorkItem` records. Unsupported repository or review capabilities remain
unregistered and fail explicitly through the resolver.

GitHub issues migrate offline and idempotently during an approved maintenance
window. The migration preserves provider identity, metadata, comments, Paid
state, assignments, agent-run history, relationships, provenance, and the
existing trusted-GitHub-user configuration. It reconciles issues created in the
window and avoids permanent dual-write.

## Alternatives Considered

| Alternative | Decision |
| --- | --- |
| Add a separate Linear credential, mapping, and provider interface to `WorkItem` | Rejected: it duplicates existing configuration and allows the two paths to diverge. |
| Keep GitHub and Linear on separate ticket models | Rejected: it preserves duplicate browsing, assignment, and workflow behavior. |
| Move pull requests into `WorkItem` | Rejected: review, approval, branch, commit, and merge behavior are distinct from ticket tracking. |
| Continue GitHub and unified storage indefinitely with dual writes | Rejected: it makes reconciliation and authority permanent instead of bounded to migration. |

## Trade-offs and Consequences

The unified model adds reconciliation, migration, and conflict-handling
complexity, and the exact Linear API guarantees still require implementation
research. In return, it gives GitHub and Linear tickets a consistent local
workflow while retaining each provider's credential and transport boundary.
The default-off guard makes rollout reversible at the behavior boundary, but
disabling it intentionally preserves imported records rather than undoing a
migration.

## Rollout Guard

`unified_work_items` is a default-off feature flag. Implementation issue
[#4855](https://github.com/viamin/paid/issues/4855), “Phase 1: define
unified work-item domain and provider contracts,” owns adding it to
`FeatureFlags::DEFINITIONS` and wiring the runtime decision.

Project-scoped entry points evaluate
`FeatureFlags.enabled?(:unified_work_items, project:)`. Account-scoped ticket
browsing, Linear connection, and trust-default surfaces establish
`Current.account` and evaluate `FeatureFlags.enabled?(:unified_work_items)`,
which reads that account's `tenant_settings.features` override. They must not
render or mutate unified state without account context.

The authorized project feature-flag management surface and the corresponding
account tenant feature override are the enablement surfaces. Disabling the
guard preserves imported records, audit data, and explicit overrides; it does
not delete or reverse migrated data. Keep the guard until a closeout audit
verifies synchronization, migration, trust, conflicts, ticket-to-PR
relationships, rollback, and regression evidence.

## Implementation Plan

1. Define the `WorkItem` model and reconciliation records, reusing
   `TrackerConfiguration` for Linear credentials and mappings.
2. Implement the Linear adapter operations and synchronization with pagination,
   rate-limit handling, explicit unsupported-operation results, and idempotent
   upserts.
3. Register the Linear work-item factory in the existing automation resolver
   and enforce the trust, assignment, lifecycle, and guard contracts.
4. Run the offline GitHub migration in an approved maintenance window and
   reconcile work created during that window.
5. Close out against the EARS claims and rollout-guard evidence before changing
   the RDR status or removing the guard.

## Validation

Validate the implementation against the unified-work-items EARS claims:
provider-identity upserts, Linear pagination and rate-limit outcomes,
trust-boundary admission, lifecycle-loop and conflict handling, GitHub
migration idempotency and maintenance-window reconciliation, ticket-to-PR
relationships, and default-off guard behavior. The RDR closeout audit must
record synchronization, migration, trust, conflict, relationship, rollback,
and regression evidence before the guard is removed.
