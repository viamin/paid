---
parent: PAID
prefix: UNIFIED-WORK-ITEMS
---

# Low-Level Design: Unified Work Items

RDR-079 Phase 1 establishes the contract and default-off rollout guard. The
remaining delivery work is tracked by #4854.

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
separate typed collections. A relation records the unified relation kind, the
provider-native kind it was mapped from, and the provider's dependency target,
so normalizing a relation never discards provider meaning. An assignment
records its provider, Paid, or inherited provenance and any explicit Paid
override actor and time. A
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
## Context and problem

Paid's issue workflows are GitHub-centered. Users need to browse external
tracker tickets, associate them with one or more repository-backed projects,
start Paid workflows from a project page, bulk-assign tickets, and preserve
issue-level assignment choices. The tracking issue (#4854) confirms that tickets
represent work to be done, while pull requests represent completed work
awaiting review. The design therefore unifies tracker-backed tickets without
moving pull-request review semantics into the ticket model.

`IssueTrackers::Adapters::Base` is the existing provider-neutral tracker
operation seam; its Linear adapter is selected by
`IssueTrackers::AdapterFactory` from `TrackerConfiguration`. Subsequent phases
add a persisted `WorkItem` model as the local identity and reconciliation store, not
a second automation provider interface. A Linear `WorkItem` records
the provider resource and normalized state fetched through that adapter; it
does not duplicate the account's credential or `project_mapping`.
`TrackerConfiguration` remains authoritative for the account Linear
connection, integration credential, configuration scope, and mapping. External
tracker data, comments, webhooks, and issue text remain untrusted at the
integration boundary.

## Scope and boundaries

The capability covers:

- a provider-neutral `WorkItem` identity and normalized ticket fields;
- typed provider extensions and retained raw payloads for reconciliation;
- one account-wide Linear connection, health, configurable synchronization,
  and the supported Linear ticket data surface;
- unassigned-first browsing, individual and bulk assignment, mapping modes,
  issue overrides, provenance, previews, review flags, and execution-project
  selection;
- provider-neutral workflow, permission, trust, identity, comment, and
  lifecycle behavior;
- bidirectional lifecycle mapping with loop prevention and conflict review;
- offline idempotent GitHub issue migration and maintenance-window
  reconciliation; and
- explicit relationships from work items to separate pull-request artifacts.

The first version supports Linear teams for trust and identity, but not
Linear-team-to-Paid-project bulk mapping. It supports one Linear workspace
while keeping connection identity extensible. Linear-specific label management
and automatic cross-tracker text/reference discovery are out of scope.

## Design

### Provider-neutral work-item contract

A work item has a stable provider/resource identity, normalized title, body,
state, priority, timestamps, labels, comments, relations, attachments, and
archive/deletion state. Provider-specific data is represented through typed
extensions; raw payloads are retained for inspection and reconciliation. A
work item carries assignment provenance and explicit issue-level overrides so
mapping changes cannot silently replace a human decision.

Pull requests remain review artifacts with their branch, commit, approval,
merge, and review lifecycle. A relationship model links a work item to a
pull request when Paid can discover the relationship; otherwise a user can
link it explicitly.

### Existing tracker and automation seams

`IssueTrackers::Adapters::Linear` remains the provider-specific transport for
connection validation, reads, comments, status writes, and PR links. Sync and
write services use the adapter selected from the account's
`TrackerConfiguration`, then upsert the corresponding `WorkItem` by provider
identity. The local model holds imported state, reconciliation metadata,
assignment provenance, overrides, and relationships; it holds neither a second
Linear credential nor a second ticket-to-project mapping.

Automation retains its existing `Automation::Providers::WorkItemProvider`
contract. The Linear implementation is registered as
`Automation::Providers::Resolver.register(:linear, work_item: ...)`; a project
selects it through its `provider_type` of `:linear`. That factory resolves the
account's Linear `TrackerConfiguration` and operates on its persisted
`WorkItem` records. Repository and review capabilities remain registered only
where Linear supports them, so the resolver raises its existing explicit error
for an unavailable capability rather than silently using GitHub.

### Linear synchronization

The account's existing Linear credential surface is reused for one workspace
connection. Synchronization is paginated, idempotent by provider identity,
and defaults to a configurable 15-minute cadence. It records connection
health, rate-limit and unsupported-operation outcomes, and retains supported
metadata, comments, projects, teams, users, relations, dependencies, cycles,
attachments, and archive/delete state. Comment posting uses the configured
API-key identity when project policy permits; imported comments are never
reposted.

The exact Linear API capabilities, pagination behavior, rate limits, comment
and status support, and deletion semantics remain open until confirmed during
implementation. Unsupported operations must be reported rather than treated
as successful synchronization.

### Assignment, trust, and lifecycle policy

The browser presents unassigned work first and supports required filters,
individual assignment, and bulk assignment. Linear project mappings support
current-and-future, future-only, and no-auto-assignment modes. Mapping-level
and issue-level default execution projects are separate from assignment; a
run started from a ticket can choose among assigned projects according to
those defaults.

Mapping changes show affected assignments before confirmation and flag review
when Linear projects or mappings change. GitHub-sourced content continues to
be admitted only through the existing GitHub-user allowlist and `issue.trusted?`
gate. Account trusted-team/user defaults, project additions/overrides, and
explicit Paid-to-provider identity mappings are an additional admission path
for non-GitHub providers; they do not replace or widen the GitHub path.
Imported text never becomes trusted merely because it was synchronized.

Lifecycle mappings work in both directions, prevent synchronization loops,
and surface simultaneous conflicting changes for human review. Agent-run
lifecycle writes are independently configurable.

### GitHub migration and rollout

GitHub issues migrate offline and idempotently into the unified model while
preserving provider identity, metadata, comments, Paid state, assignments,
agent-run history, relationships, assignment provenance, and the existing
trusted-GitHub-user configuration. The migration reconciles issues created
during its maintenance window and avoids long-term dual-write. Existing GitHub
issue workflows continue through the unified contract after cutover.

Phase 1 added the default-off `unified_work_items` feature flag and its
project-scoped rollout guard. Future project-scoped entry points evaluate
`FeatureFlags.enabled?(:unified_work_items, project:)`. Account-scoped
surfaces (the account ticket browser, Linear connection, and account trust
defaults) establish `Current.account` and evaluate
`FeatureFlags.enabled?(:unified_work_items)` against that account's
`tenant_settings.features` override; they do not render or mutate unified
state without an account context. Future implementations apply the guard to
synchronization, workflow admissions, browser and
project-page browsing/read surfaces, assignment, lifecycle operations, and
account settings. While it is disabled, those surfaces continue existing
GitHub issue behavior and do not expose unified-ticket behavior. Disabling it
preserves imported records, audit data, and explicit overrides; it does not
silently delete or revert migrated data. The flag remains until the
[RDR-079](../../rdrs/RDR-079-unified-tracker-work-items.md) closeout audit
passes with synchronization, migration, trust, conflict, relationship,
rollback, and regression evidence.

## Decisions and alternatives

| Decision | Rationale | Alternative rejected |
|---|---|---|
| Compose `WorkItem` with existing tracker and automation seams | `TrackerConfiguration` already owns the connection credential and mapping, `IssueTrackers` owns provider transport, and `Automation::Providers::Resolver` owns automation capability registration. `WorkItem` supplies durable normalized state and reconciliation without duplicating any of those responsibilities. | Create a second Linear credential, mapping, or provider interface; that would create divergent configuration and behavior. |
| Keep pull requests as separate review artifacts | The tracking issue (#4854) distinguishes work tickets from completed work awaiting review; PR approval, merge, branch, and commit semantics remain distinct. | Migrate pull requests into the ticket model; that conflates review with work tracking. |
| Migrate GitHub issues offline and idempotently | The tracking issue (#4854) preserves existing state and bounded maintenance-window reconciliation without permanent dual-write. | Add Linear abstractions without GitHub migration; existing workflows would remain on a second model. |
| Preserve explicit mapping provenance and overrides | The tracking issue (#4854) requires bulk mapping without silently overwriting issue-level decisions, with preview and review flags. | Treat the latest mapping as authoritative for every issue; this loses human intent. |
| Use the default-off `unified_work_items` account-and-project rollout guard owned by implementation issue #4855 | Project entry points have a project context, while account settings and browsing must use the current account's tenant override. This keeps every surface unavailable until the appropriate scoped enablement, and assigns the flag definition and runtime wiring to a traceable implementation owner. | Enable the unified model globally, expose read surfaces while the flag is off, or invent a parallel rollout mechanism. |

## Cascade ordering and segment boundaries

Implementation follows tracking issue #4854 in this order:

1. Define the domain model, provider contracts, raw payloads, relationships,
   provenance, overrides, conflict records, and the default-off guard.
2. Implement Linear connection health, pagination, synchronization, supported
   provider operations, and error/rate-limit reporting.
3. Implement assignment, mapping modes, overrides, previews, trust/identity,
   lifecycle mappings, conflicts, and execution-project policy.
4. Integrate browser and project-page surfaces and route existing issue
   workflows through the contract.
5. Build offline GitHub migration, maintenance-window reconciliation, and
   GitHub consumer cutover.
6. Add pull-request relationships and regression coverage, then perform the
   RDR-079 closeout validation against migration, trust, rollback, and
   workflow evidence.

The segment owns the ticket model, tracker adapters, synchronization,
assignment/trust policy, migration, and ticket-to-PR relationship. It composes
the reusable policies owned by
`docs/intent/tenant-access-control/`,
`docs/intent/upstream-issue-pickup/`,
`docs/intent/rdr-rollout-guards/`, and
`docs/intent/review-pull-request/`. This segment owns the composition of the
existing tracker-adapter and automation work-item-provider seams; their shared
contracts remain owned by their existing components.

## Open decisions

The following decisions must be settled before implementation locks the design:
the exact Linear API capabilities and rate-limit/pagination behavior; the
extension of trusted-team/user and provider identity mappings; and the
pragmatic migration/reconciliation tooling while Paid is not production-bound.
