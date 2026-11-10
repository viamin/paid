# RDR-079: Unified Tracker Work Items with Linear Integration and GitHub Issue Migration

> Revise during planning; lock at implementation. If wrong, abandon code and iterate the RDR.

## Metadata

- **Date**: 2026-11-05
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-010](RDR-010-multi-tenancy-rbac.md), [RDR-012](RDR-012-github-integration.md), [RDR-051](RDR-051-lid-aware-agent-runs.md), [RDR-053](RDR-053-new-feature-creation.md), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md)
- **Tracking issues**: #4854 (umbrella), #4855–#4860 (phases), #4861 (closeout)
- **Implementation status**: Phase 1 provider-contract and rollout-guard
  work is present in code and checked EARS claims, while #4855 remains open
  for issue-level reconciliation. Phases #4856–#4861 remain open. The design
  is still Draft; partial foundation work is not final design acceptance.
- **LID**: Full mode, version 1.3.0; the linked LLD and EARS artifacts record
  the implementation cascade.

## Problem Statement

Paid currently has GitHub-centric issue workflows and a tracker adapter layer
whose Linear issue listing is not implemented. Users need to browse external
tracker tickets, associate them with one or more repository-backed Paid
projects, and start Paid issue workflows from the project page. Linear project
mappings need bulk assignment while preserving issue-level overrides.

**User-confirmed framing.** Tickets represent work to be done; pull requests
represent completed work awaiting review. Paid should therefore build an
extensible unified work-item model for tracker-backed tickets, implement Linear
first, and migrate GitHub issues into that model while keeping pull requests as
separate review artifacts. The feature brief marks this framing
`selected_framing_confirmed: true`.

The desired user outcome is that a configured account can browse and assign
Linear tickets, run Paid workflows against them, retain trusted-comment and
identity behavior, and have existing GitHub issue workflows continue through
the unified model. The outcome is a target, not evidence that it has already
been achieved.

## Context

### Supplied problem observations and evidence

The feature brief supplies these observations:

- Paid has GitHub-centric issue workflows.
- Users need external-ticket browsing, project association, project-page run
  initiation, bulk mapping, and issue-level assignment overrides.
- Repository inspection found a Linear-capable tracker configuration and
  adapter interface, while Linear `list_issues` and `update_status` are
  currently unimplemented.
- The existing Paid `Issue` model and project issue table are GitHub-oriented.

Affected stakeholders named in the brief are account admins, project
maintainers, project members, agents, and human Paid actions that post
comments or change lifecycle state.

### Repository boundaries

Paid is a Rails control plane with PostgreSQL persistence, Temporal for
long-running workflows, GoodJob for lightweight scheduled jobs, Pundit for
authorization, and account/project-scoped configuration. The architecture
describes GitHub polling and issue-to-PR workflows as existing platform
concerns; `docs/DATA_MODEL.md` documents the current `issues` table as a local
cache of tracked GitHub issues.

The project style guide requires capability-oriented services, thin
controllers, structural policy in code, and semantic judgments through
`agent_harness`. External tracker data, comments, webhooks, and issue text are
untrusted at their boundary. This RDR consequently treats synchronization,
identity, trust, assignment provenance, and state transitions as explicit data
and policy rather than as provider-specific controller logic.

## Research Findings

The following findings are from repository inspection and are not customer
evidence:

1. `app/models/tracker_configuration.rb` supports `github_issues`, `jira`,
   `linear`, `azure_devops`, `mcp`, and `generic_webhook`, and can be attached
   to an `Account`, `User`, or `Project`. It resolves adapters through
   `IssueTrackers::AdapterFactory`.
2. `app/services/issue_trackers/adapter_factory.rb` maps `linear` to
   `IssueTrackers::Adapters::Linear`.
3. `app/services/issue_trackers/adapters/base.rb` defines the existing
   provider contract for listing/fetching issues, comments, status updates,
   pull-request links, and connection validation. The base adapter already
   exposes tracker configuration, credentials, project mapping, and quiet-mode
   comment suppression.
4. `app/services/issue_trackers/adapters/linear.rb` currently raises
   `NotImplementedError` for `list_issues`, `get_issue`, `add_comment`,
   `update_status`, `link_pr`, and `validate_connection!`. This is the concrete
   implementation gap for Linear.
5. Account-wide Linear credentials already have a local representation:
   `Account#linear_tokens`, `LinearToken`, the Linear integration provider, and
   `linear_tokens` routes/controllers/views. `LinearToken` validates the
   `lin_api_...` format and supports revocation. The brief's one-connection
   requirement is therefore a new usage constraint over an existing credential
   surface, not evidence that synchronization already exists.
6. `app/models/issue.rb` is the current Paid issue aggregate. Its associations
   include agent runs, parent/sub-issues, dependencies, and feature-intent
   links; it also contains GitHub-specific source constants, GitHub trust
   predicates, GitHub labels, and GitHub-number identity. `docs/DATA_MODEL.md`
   describes the current `issues` table as GitHub-backed.
7. `Prompts::BuildForIssue.fetch_trusted_comments` and the issue-analysis
   admission path filter issue comments through the existing GitHub trust model.
   `Project` stores trusted GitHub usernames and validates reviewer identity
   against them. Extending trusted comments to Linear therefore requires an
   explicit provider-neutral trust and identity boundary; it must not simply
   treat imported Linear text as trusted.
8. `app/services/automation/providers/work_item_provider.rb` already describes
   a provider-neutral work-item provider boundary, including non-integer
   external identifiers, while `app/services/automation/providers/github/work_item_provider.rb`
   implements the GitHub provider. This is a useful contract seam but does not
   by itself provide a persisted unified work-item model.
9. `Issues::ParseDependencies` parses local and cross-repository dependency
   declarations from issue bodies and comments. Existing issue-filing tools
   call it after creating GitHub issues, so migration and future tracker-backed
   work items must preserve dependency provenance without making provider text
   trusted by default.
10. The repository's rollout mechanism is `FeatureFlags::DEFINITIONS` plus
    `FeatureFlags.enabled?(..., project:)`, with tenant/project enablement
    surfaces and explicit cleanup criteria. Phase 1 adds the default-off
    `unified_work_items` flag and a project-scoped guard; account-scoped
    surfaces remain planned.

### Unknowns preserved from the brief

The exact Linear API capabilities, pagination and rate-limit behavior are not
confirmed here. The existing trusted-comment and identity data model will need
extension for Linear teams/users and GitHub mappings. The maintenance-window
migration tooling can be pragmatic because Paid is not production-bound. These
are hypotheses/implementation questions, not repository facts.

## Proposed Solution

Create a provider-neutral `WorkItem` domain model and provider identity layer,
with typed provider extensions and retained raw provider payloads. A work item
has a stable provider/resource identity, normalized title/body/state/priority,
timestamps, labels, comments, relations, attachments, and archive/delete
state, while provider-specific fields remain typed extensions and raw payloads
remain available for reconciliation. `PullRequest` remains a separate review
artifact and relates to work items through an explicit relationship model.

The model and services should support:

- one account-wide Linear connection using the existing account credential
  surface, with connection health and a configurable automatic sync cadence
  defaulting to 15 minutes;
- full Linear ticket synchronization, including metadata, comments,
  dependencies/relations, cycles, attachments, archive/delete state, projects,
  teams, users, and raw payloads, subject to confirmed API capabilities;
- an unassigned-first browser with filters and individual/bulk assignment to
  repository-backed Paid projects;
- Linear-project mappings with current-and-future, future-only, or
  no-auto-assignment behavior; issue-level customization and complete
  replacement overrides; assignment provenance; review flags when mappings or
  Linear projects change; and preview/confirmation for affected assignments;
- mapping-level and issue-level default execution projects, with a choice
  among assigned projects when starting a Paid issue workflow;
- provider-neutral issue workflow behavior for enhancement, analysis,
  planning, agent runs, comments, priority/lifecycle/review controls, and
  project permissions;
- comments posted to Linear as the configured API-key user when project
  settings permit, while imported comments are retained and never reposted;
- account trusted-team/user defaults with project additions/overrides and
  explicit Paid-to-Linear and Paid-to-GitHub identity mappings;
- bidirectional Linear/Paid lifecycle mappings with account defaults and
  project/mapping overrides, loop prevention, and human review for simultaneous
  conflicting changes; agent-run lifecycle writes remain independently
  configurable;
- an offline, idempotent GitHub issue migration that preserves identity,
  metadata, comments, Paid state, assignments, agent-run history,
  relationships, assignment provenance, and reconciliation of issues created
  during the migration window; and
- separate GitHub pull-request review artifacts with automatic links for
  Paid-created PRs where discoverable and explicit user linking otherwise.

The first version supports Linear teams for trust and identity but does not
implement Linear-team-to-Paid-project bulk mapping. It supports one Linear
workspace/connection now while keeping connection identity extensible for
future multiple connections. Linear-specific label-management operations and
automatic cross-tracker text/reference discovery remain out of scope.

### Rationale

The provider-neutral boundary prevents Linear-specific behavior from becoming
a second issue system and lets the existing GitHub workflow migrate without
moving pull-request review into the ticket domain. Explicit provenance and
override records prevent mapping changes from silently overwriting human
decisions. Raw payload retention and idempotent reconciliation make provider
behavior inspectable while allowing normalized Paid workflows to remain stable.
Separating trust/identity from synchronization prevents imported external text
from bypassing the project's existing prompt-injection and authorization
boundaries.

## Alternatives Considered

### Keep Linear separate from GitHub

This would reduce migration risk initially, but it would preserve duplicate
issue workflows, assignment semantics, trusted-comment paths, and run-start
surfaces. It does not satisfy the user-confirmed unified work-item framing.

### Migrate pull requests into the unified issue model

Rejected because the supplied framing distinguishes work tickets from
completed work awaiting review. Pull requests retain review lifecycle,
approval, merge, branch, and commit semantics that should remain in the
separate review-artifact domain.

### Use Linear-only abstractions without migrating GitHub issues

Rejected because existing GitHub issue workflows would remain permanently on a
second data model and the desired GitHub migration/reconciliation outcome
would not be met.

### [inferred] Use the existing feature-flag mechanism as the runtime guard

This is the proposed guard rather than a user-confirmed product choice. It
matches the repository's existing `FeatureFlags::DEFINITIONS` and
`FeatureFlags.enabled?` mechanism and allows synchronization and workflow
cutover to be enabled per project while migration remains controlled.

## Trade-offs and Consequences

Positive consequences:

- Linear and GitHub tickets share workflow, assignment, trust, and execution
  semantics while retaining provider identity and raw data.
- Explicit mapping provenance, overrides, previews, and review flags make
  bulk assignment changes auditable and reversible at the decision level.
- Offline migration avoids long-term dual-write and gives reconciliation a
  bounded, testable window.
- A separate pull-request artifact preserves review semantics and permits
  discoverable or explicit ticket relationships.

Costs and risks:

- The model, migration, and consumers are a broad schema and workflow change;
  every GitHub issue consumer must be cut over without losing existing Paid
  state.
- Provider API pagination, rate limits, deleted/archive semantics, comment
  authorship, and relation shapes may constrain the full Linear representation.
- Bidirectional status synchronization can loop or lose a simultaneous change
  without durable source/version metadata, conflict detection, and idempotent
  writes.
- Identity and trust mappings add administrative surface and create a risk of
  admitting untrusted external content if policy boundaries are bypassed.
- One workspace today limits operational complexity but leaves a future
  multiple-connection migration to the identity model.

## Rollout Guard

The Phase 1 provider-contract implementation adds the default-off
`unified_work_items` feature flag to `FeatureFlags::DEFINITIONS` and protects
new project-scoped entry points through
`FeatureFlags.enabled?(:unified_work_items, project:)`. Account-scoped
surfaces remain planned and must establish `Current.account` before evaluating
the account tenant-setting override.

- **Default:** disabled for all tenants and projects.
- **Enablement surface:** tenant/project feature settings using the existing
  feature-flag administration surface, after the account connection,
  synchronization, migration rehearsal, trust, and reconciliation checks pass.
- **Rollback:** disable the flag for affected projects; stop new unified-model
  workflow admissions and synchronization writes, preserve imported records
  and audit data, and route unresolved conflicts/assignments to review. Do not
  delete migrated data or silently revert explicit overrides.
- **Cleanup criteria:** remove the flag only after the RDR closeout audit
  verifies the complete provider-neutral workflow, Linear synchronization,
  GitHub migration/reconciliation, trust/identity boundaries, status conflict
  handling, PR relationships, and regression suite. Until then, every issue
  must preserve the default-off guard.

Migration rehearsal and offline GitHub migration are additionally
**migration-only** operations: they must not expose unified runtime behavior
until the feature flag is enabled and the migration issue records a reviewed
cutover result.

## Implementation Plan

### Phase 1 — Domain model and provider contracts (implemented)

Define provider/resource identity, normalized work-item fields, typed provider
extensions, raw payload retention, comments/relations/attachments, assignment
provenance and overrides, status mappings/conflicts, and the separate
work-item-to-pull-request relationship. Extend provider-neutral adapter
contracts without removing GitHub compatibility. Add the rollout flag and
mechanically guard new project-scoped runtime entry points. Phase 1 supplies
the immutable contract and compatibility conversion; persisted reconciliation
records remain a later phase.

### Phase 2 — Linear synchronization and provider operations

Implement account-wide Linear connection validation and health, paginated
full synchronization with a configurable 15-minute default, idempotent upsert,
raw payload retention, comments, projects, teams, users, relations,
dependencies, cycles, attachments, archive/delete state, and rate-limit/error
reporting. Implement comment posting, status updates, and provider PR links
where the confirmed API supports them; record unsupported operations clearly.

### Phase 3 — Assignment, mappings, overrides, and lifecycle policy

Implement unassigned-first query behavior, filters, individual/bulk
assignment, Linear project mapping modes, issue-level customize/replace
overrides, provenance, affected-issue review flags, mapping preview and
confirmation, default execution projects, permissions, trusted teams/users and
identity mappings, bidirectional status mappings, conflict detection, and
independent agent-run lifecycle status configuration.

### Phase 4 — Browser and Paid workflow integration

Build the issue browser and project-page surfaces. Route enhancement, analysis,
planning, agent-run, comment, priority/lifecycle/review, and trusted-comment
flows through the unified work-item contract. Preserve repository-backed
project requirements and project/member/admin/maintainer authorization.

### Phase 5 — Offline GitHub migration and cutover

Create an idempotent offline migration and reconciliation tool. Preserve
GitHub identity/provenance, metadata, comments, Paid state, assignments,
agent-run history, dependencies and relationships; reconcile issues created
during the maintenance window; then cut existing GitHub issue consumers over
without long-term dual-write. Keep GitHub issue workflows operational through
the unified model.

### Phase 6 — Pull-request relationships and regression coverage

Keep pull requests in the review-artifact model, add discoverable links for
Paid-created PRs and explicit linking, and cover provider, migration,
permissions, trust, assignment, status-loop/conflict, comment de-duplication,
workflow, and rollback behavior with focused and regression tests.

### Phase 7 — RDR closeout and validation

Run the closeout checklist against the shipped implementation, migration
evidence, tests, runtime guard, documentation, issue dependencies, and open
decisions. Update this RDR and the index only when acceptance is evidenced;
otherwise keep Draft/Partially Implemented status and file focused follow-up
issues with explicit dependencies.

## Validation

### Planned EARS claim IDs

The following provisional IDs give the issue tree stable LID references;
`lid_planning` will create the canonical LLD/EARS artifacts and may refine
wording while preserving traceability:

- `UNIFIED-WORK-ITEMS-001` — provider identity, normalized fields, typed
  extensions, raw payloads, and separate PR artifacts exist without breaking
  GitHub consumers.
- `UNIFIED-WORK-ITEMS-002` — an account can connect one Linear workspace and
  observe sync health, cadence, pagination, rate-limit, and unsupported-operation
  outcomes.
- `UNIFIED-WORK-ITEMS-003` — Linear tickets synchronize full supported data,
  comments, relations, cycles, attachments, archive/delete state, and
  idempotent provider identity.
- `UNIFIED-WORK-ITEMS-004` — mappings, assignments, overrides, provenance,
  previews, review flags, and default execution projects behave as specified.
- `UNIFIED-WORK-ITEMS-005` — browser and project-page workflows enforce
  permissions, trusted comments, identity mappings, comment de-duplication,
  and agent-run lifecycle configuration.
- `UNIFIED-WORK-ITEMS-006` — status mappings synchronize bidirectionally with
  loop prevention and conflict review.
- `UNIFIED-WORK-ITEMS-007` — GitHub issues migrate offline, idempotently, and
  reconcile the maintenance window while preserving history and provenance.
- `UNIFIED-WORK-ITEMS-008` — pull requests remain separate review artifacts
  and link to work items when discoverable or explicitly linked.
- `UNIFIED-WORK-ITEMS-009` — the rollout guard remains default-off until
  closeout evidence authorizes safe default behavior.

### Acceptance scenarios

Validation must demonstrate that:

1. A configured account sees Linear connection and automatic sync status;
   default browser ordering shows unassigned work first and supports required
   filters, individual assignment, and bulk assignment.
2. A maintainer maps a Linear project to one or more repository-backed Paid
   projects using current-and-future, future-only, or no-auto-assignment
   behavior, customizes or replaces one issue's assignment, and sees preserved
   provenance. Mapping changes present an affected-issue preview and flag
   review instead of silently overwriting explicit overrides.
3. A user starts a Paid run from a Linear ticket, receives the configured
   mapping/issue default execution-project behavior, and can choose among
   assigned projects.
4. Paid and agent comments post as the configured API-key user when allowed;
   imported comments are not reposted; trusted teams/users and mapped
   identities control prompt admission with account defaults and project
   overrides.
5. Lifecycle changes synchronize through configured mappings without loops;
   simultaneous changes are flagged, and agent-run status writes can be
   disabled independently.
6. An offline GitHub migration preserves identity, metadata, comments, Paid
   state, assignments, agent-run history, relationships, and provenance; a
   rerun is idempotent; maintenance-window creations reconcile; existing
   GitHub workflows still function through the unified model.
7. GitHub pull requests remain review artifacts and link to work items through
   discoverable Paid-created relationships or explicit user links.
8. The feature flag disables new runtime behavior without deleting imported
   records, and the closeout checklist identifies any remaining gaps.

### Reconsideration conditions

Reconsider this recommendation if confirmed Linear API limitations make the
selected synchronization or comment behavior infeasible, or if migration
shows that GitHub issue workflows require a compatibility boundary rather than
direct unified-model adoption. Those conditions are hypotheses to test, not
claims about current API behavior.
