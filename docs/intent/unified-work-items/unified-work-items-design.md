---
parent: PAID
prefix: UNIFIED-WORK-ITEMS
---

# Low-Level Design: Unified Tracker Work Items

> This is a planned capability. Its rollout guard and open product decisions
> require confirmation before implementation.

## Context and problem

Paid's issue workflows are GitHub-centered. Users need to browse external
tracker tickets, associate them with one or more repository-backed projects,
start Paid workflows from a project page, bulk-assign tickets, and preserve
issue-level assignment choices. The authored proposal confirms that tickets
represent work to be done, while pull requests represent completed work
awaiting review. The design therefore unifies tracker-backed tickets without
moving pull-request review semantics into the ticket model.

`Automation::Providers::WorkItemProvider` is the existing provider-neutral
adapter contract: its implementations map provider-native tickets to
`Automation::Providers::Data::Issue`, while automation policy operates on work
items. The proposed persisted `WorkItem` model is a separate identity and
reconciliation record composed with that adapter contract, not a second
provider interface. The existing account-wide Linear credential surface is
also a useful boundary, but Linear operations and the persisted model are not
yet complete. External tracker data, comments, webhooks, and issue text remain
untrusted at the integration boundary.

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

Subject to the open product decision below, the proposed
`unified_work_items` runtime guard is project-scoped and disabled by default.
Its implementation must add `:unified_work_items` to
`FeatureFlags::DEFINITIONS` and evaluate every new unified runtime entry point
through `FeatureFlags.enabled?(:unified_work_items, project:)`, including
synchronization, workflow admissions, browser and project-page browsing/read
surfaces, assignment, and lifecycle operations. While it is disabled, those
surfaces continue existing GitHub issue behavior and do not expose
unified-ticket behavior. Disabling it preserves imported records, audit data,
and explicit overrides; it does not silently delete or revert migrated data.
The flag remains until its closeout audit passes with synchronization,
migration, trust, conflict, relationship, rollback, and regression evidence.

## Decisions and alternatives

| Decision | Rationale | Alternative rejected |
|---|---|---|
| Use one provider-neutral work-item model, with Linear first | The authored proposal requires unified ticket workflows while preserving provider identity and raw data for reconciliation. | Keep Linear separate from GitHub; that retains duplicate workflows and does not meet the confirmed framing. |
| Keep pull requests as separate review artifacts | The authored framing distinguishes work tickets from completed work awaiting review; PR approval, merge, branch, and commit semantics remain distinct. | Migrate pull requests into the ticket model; that conflates review with work tracking. |
| Migrate GitHub issues offline and idempotently | The authored plan preserves existing state and bounded maintenance-window reconciliation without permanent dual-write. | Add Linear abstractions without GitHub migration; existing workflows would remain on a second model. |
| Preserve explicit mapping provenance and overrides | The authored plan requires bulk mapping without silently overwriting issue-level decisions, with preview and review flags. | Treat the latest mapping as authoritative for every issue; this loses human intent. |
| Provisionally propose `unified_work_items` as the default-off rollout guard for every new unified runtime entry point | This planned contract proposes a project-scoped guard so the unified model, including browse/read surfaces, stays unavailable until an authorized project enablement. The flag name and enablement surface remain an open product decision; see Open decisions. | Enable the unified model globally, expose read surfaces while the flag is off, or invent a parallel rollout mechanism. |

## Cascade ordering and segment boundaries

Implementation follows the authored plan in this order:

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
   RDR closeout validation against migration, trust, rollback, and workflow
   evidence.

The segment owns the ticket model, tracker adapters, synchronization,
assignment/trust policy, migration, and ticket-to-PR relationship. It composes
the reusable policies owned by
`docs/intent/tenant-access-control/`,
`docs/intent/upstream-issue-pickup/`,
`docs/intent/rdr-rollout-guards/`, and
`docs/intent/review-pull-request/`. The currently unmapped
`Automation::Providers::WorkItemProvider` adapter and tracker-adapter seams
must be mapped to an owning intent segment before implementation crosses that
boundary.

## Open decisions

The following decisions must be settled before implementation locks the design:
the exact Linear API capabilities and rate-limit/pagination behavior; the
extension of trusted-team/user and provider identity mappings; the pragmatic
migration/reconciliation tooling while Paid is not production-bound; and the
rollout-flag name and enablement surface.
