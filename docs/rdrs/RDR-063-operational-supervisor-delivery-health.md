# RDR-063: Operational Supervisor for Delivery Health

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-17 (substantially revised 2026-10-28)
- **Status**: Draft — normal design review has not accepted this decision
- **Type**: Operations + AI Safety + Automation
- **Priority**: P3
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-023](RDR-023-automation-modularization-architecture.md), [RDR-047](RDR-047-work-category-queue-priority.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-054](RDR-054-prompt-assembly-service.md)
- **Related Intent**: [Operational Supervisor LLD](../intent/operational-supervisor/operational-supervisor-design.md), [Operational Supervisor EARS](../intent/operational-supervisor/operational-supervisor-specs.md)
- **Related Issues**: [viamin/paid#4341](https://github.com/viamin/paid/issues/4341) (design), [viamin/paid#4708](https://github.com/viamin/paid/issues/4708) (implementation epic), [#4709](https://github.com/viamin/paid/issues/4709) (incidents), [#4710](https://github.com/viamin/paid/issues/4710) (snapshots), [#4711](https://github.com/viamin/paid/issues/4711) (analysis), [#4712](https://github.com/viamin/paid/issues/4712) (shadow rollout), [#4713](https://github.com/viamin/paid/issues/4713) (held mitigation evaluation), [#4714](https://github.com/viamin/paid/issues/4714) (final audit)
- **Related Tests**: Planned by `OPERATIONAL-SUPERVISOR-*`; no runtime implementation or conformance tests ship in #4341

## Decision Status and Planning Boundary

This revision selects an incident-first, observation-only initial release. It
does not authorize runtime implementation, scheduling, autonomous mitigation,
or enablement. RDR-063 remains Draft until normal design review accepts it and
the linked LID artifacts merge. Every implementation issue retains its
planning hold until that boundary is verified.

The later mitigation issue, #4713, is deliberately non-authorizing. It can
proceed only after shadow evidence and a reviewed amendment select each action,
its grant, and its recovery policy. Filing that issue is not approval to build
or enable an action.

## Problem

Paid has run-, queue-, notification-, and guardrail-level signals, but no
account-scoped record that asks whether automated work is becoming delivered
pull requests at a sustainable cost. A run can look locally plausible while a
project accumulates repeated follow-ups, stalled reviews, or cost without
merges. Operators currently have to assemble that picture across several
surfaces.

The gap is an auditable, privacy-bounded operational observation loop. It is
not a gap in generic administrative authority and is not evidence that an LLM
should control delivery settings.

## Current Evidence and Reuse Audit

The October 2026 audit found these shipped primitives:

- `Notification` already provides account scoping, severity, blocking status,
  dedupe, dismissal/resolution, action URLs, broadcasting, and an Inbox bridge.
- notification rules already identify PR follow-up exhaustion, stalled draft
  PRs, repeated no-change runs, quota exhaustion, and configuration failures;
  `AgentRunAnomaly` and queue monitoring provide additional telemetry.
- account and project scheduler pauses exist, but they stop more than fresh
  issue admission and are therefore too broad for a supervisor mitigation.
- Auto-Pick has a centralized project gate, and queue ordering already favors
  workable PR continuations. A second LLM-controlled priority system would
  duplicate RDR-047 and risk conflicting policy.
- guardrails already own run token, cost, time, and loop limits. The supervisor
  must observe their outcomes, not replace or weaken them.
- recovery jobs and explicit escalation/follow-up caps already handle known
  local failures. A supervisor action may compose with an existing primitive
  only when its narrower semantics and ownership are preserved.
- GoodJob supplies bounded recurring scheduling, and all application LLM calls
  are required to use `agent_harness`.

No `OperationalSupervisor` runtime implementation or accepted implementation
tree was present when #4341 was opened. The canonical planning tree is now
#4708–#4714. Earlier duplicate planning trees are not parallel scope.

## Decision

Build, after design acceptance, an account-scoped Operational Supervisor in
two separately reviewed stages:

1. **Observation stage (selected initial scope).** Deterministic Rails code
   builds a versioned, sanitized delivery-health snapshot. An LLM reached only
   through `agent_harness` classifies patterns into a strict structured schema.
   Validated findings become first-class supervisor incidents and an authorized
   dashboard/Inbox projection. This stage cannot mutate delivery controls.
2. **Mitigation stage (held future scope).** Shadow evidence may motivate a
   reviewed amendment selecting one or more narrowly scoped, expiring actions.
   No action is in the initial runtime allowlist except `open_incident`.

The supervisor does not compute a hard-coded “delivery quality score.” Rails
calculates factual counts, cohorts, rates, ages, percentiles, and availability;
the LLM makes the semantic judgment about whether their combination represents
degradation. Rails then enforces schema, authorization, freshness, target
membership, idempotency, and any separately approved action policy.

## Selected Scope

### Goals

- Give authorized operators one durable account-level view of delivery-health
  findings and the exact sanitized facts supporting them.
- Detect combinations of factual signals that local rules do not express.
- Reuse existing notifications, queue policy, guardrails, and recovery paths.
- Make supervisor health, model/prompt identity, and every later action receipt
  auditable.
- Prove at the data-contract boundary that forbidden content cannot reach the
  supervisor LLM.

### Non-goals

- No autonomous mitigation in the initial release.
- No arbitrary database, shell, repository, GitHub, billing, credential, RBAC,
  account-wide, or code-change authority.
- No replacement for deterministic budgets, caps, queue ordering, or recovery.
- No external notifications in the selected scope; the dashboard and Inbox are
  the authoritative initial surfaces.
- No dependency on RDR-073 or RDR-075.

## Storage Decision

Use dedicated `SupervisorSnapshot`, `SupervisorIncident`, and, only if later
selected, `SupervisorMitigation` records. Do not overload `Notification` as the
source of truth.

`Notification` has useful presentation semantics but not the immutable input
digest, schema/model/prompt provenance, repeated-observation history,
mitigation lease, or recovery receipt required for an operational incident.
The supervisor incident owns those fields. A notification or Inbox entry is a
rebuildable projection keyed to the incident, resolved when the incident
resolves, and never the only copy of evidence.

Snapshots retain only the sanitized payload, schema version, account, observed
window, source-availability map, digest, and timestamps. They have bounded
retention configured as operator policy; the proposed rollout value is 30 days
and is not a semantic threshold. Incidents retain the minimum cited facts and
snapshot digest needed for audit after snapshot expiry. Raw provider responses
are not persisted.

## Snapshot Boundary

One snapshot is built per account and observation window. Project/issue/PR/run
identifiers may be included only to bind evidence and validated targets. A
versioned allowlist serializer constructs the payload from typed fields; it
does not serialize Active Record objects or arbitrary metadata hashes.

Allowed facts are:

- IDs and UI-visible project/repository slugs;
- run counts by typed goal, status, origin, and window;
- token and recorded cost totals/rates by account, project, and goal;
- Paid-authored PR counts, merge state, commit counts, and automatic follow-up
  counts;
- typed issue/PR lifecycle stage and age;
- queue depth, queue age, pause/rate-limit/guardrail counts, and phase keys;
- typed CI/review states and normalized connector timing where available;
- merge cohorts, conversion rates, rework counts, cost attribution, and source
  availability;
- existing notification, anomaly, escalation, and supervisor-incident counts.

The following are forbidden in snapshots, prompts, responses retained for
audit, incidents, and action receipts:

- issue or PR titles, bodies, comments, review text, commit messages, diffs;
- repository paths or contents;
- prompts, chat content, stdout, stderr, logs, summaries, or raw exception and
  provider text;
- user names, email addresses, private client data, credentials, tokens,
  secrets, or arbitrary metadata.

Missing sources and zero denominators are explicit. The builder fails closed
when the allowlist contract cannot represent a source. A deterministic payload
size ceiling uses per-category top-N rows ranked only by disclosed factual
quantities such as age or recorded cost, with aggregate remainder counts. This
ranking bounds input size; it is not an anomaly or quality score.

## Delivery-health Metrics

Every metric carries its window, cohort, numerator, denominator, source, and
availability. No absent denominator is converted to zero.

| Metric | Mechanical definition |
| --- | --- |
| Issue-to-PR conversion | Of trusted work items whose first automatic `create_pr` run entered the cohort window, the count with a Paid-linked PR created within the declared observation horizon divided by the eligible cohort. |
| PR-to-merge conversion | Of Paid-authored PRs opened in the cohort window and old enough to complete the declared horizon, the count merged divided by that eligible cohort. Draft/open work younger than the horizon is not a failure. |
| Cost per merged PR | Recorded cost of attributable PR-producing and continuation runs divided by attributable merged PRs for the same cohort; unavailable attribution remains unavailable. |
| Rework runs per PR | Automatic `create_pr` continuation runs after the first linked PR creation, grouped by PR. This is activity, not a quality judgment. |
| Commit count | Commits on a Paid-authored PR, reported as a fact without a “bad” threshold. |
| Stage age | Elapsed time since the typed lifecycle stage began, using the authoritative timestamp for that stage. |
| Guardrail/escalation rate | Runs with a typed guardrail or escalation outcome divided by eligible completed runs in the same window. |
| Queue service | Depth, oldest age, and wait-time distribution by existing priority/work category; the supervisor does not reorder it. |

Rails may calculate baselines and distribution deltas as descriptive facts.
It must not label a delta “poor quality,” select an operational action from a
numeric formula, or hide judgment inside a composite score. The structured LLM
finding owns category, severity, explanation, and recommendation.

## Analysis Contract

The analysis request contains only the sanitized snapshot, policy version,
incident categories, severity definitions, and current action catalog. It is
sent through `agent_harness` with a strict response schema. Each finding
contains a stable proposed fingerprint, category, severity, concise summary,
citations to snapshot field paths, affected IDs drawn from the snapshot, and a
recommended catalog action.

Rails rejects malformed output, unknown enums or fields, uncited evidence,
targets absent from the snapshot, stale snapshots, and actions outside the
catalog. Rails derives the durable fingerprint from normalized category,
targets, policy version, and cited field paths; it does not trust an arbitrary
model-supplied dedupe key. Invalid output produces no delivery mutation. A
rate-limited, deduplicated supervisor-health incident records repeated failures
without copying raw provider text.

## Incident Lifecycle and Authorization

Incidents have `open`, `waiting_for_human`, `mitigated`, and `resolved` states;
dismissal is a per-user projection concern and does not erase the account audit
record. Re-observation updates `last_seen_at` and the sanitized evidence set.
Absence from one analysis does not resolve an incident. Resolution requires a
validated later finding that marks the same fingerprint healthy, an authorized
operator resolution, or a typed source becoming permanently inapplicable.

Account members with existing operational read authority may view incidents
for projects they can access. Only account owners may configure the supervisor,
enable account observation, grant future autonomous action types, or change
retention. Project administrators may opt an individual project into an action
already granted at the account level and may revoke or recover that project's
lease. No project grant can widen the account allowlist. Every grant, revoke,
action, expiry, and recovery uses the existing execution-audit facility.

## Action Catalog, Preconditions, and Recovery

### Initial catalog

`open_incident` is the only action. Its effect is persistence and projection;
it cannot alter admission, follow-ups, priorities, settings, or external
systems.

### Held candidate catalog

The following candidates are design-resolved enough to evaluate in #4713 but
remain unauthorized until a post-shadow amendment selects them:

| Candidate | Required live preconditions | Effect and recovery |
| --- | --- | --- |
| `escalate_pr` | Critical validated incident; open Paid-linked PR in the snapshot; no active equivalent escalation; account grant and project opt-in current under lock. | Reuse the existing escalation primitive, record an idempotent receipt, and require operator acknowledgement. It does not close, merge, or enqueue work. |
| `suspend_project_new_issue_admission` | Critical validated project incident; Auto-Pick enabled; no broader scheduler pause; account grant and project opt-in current under lock; lease duration explicitly configured within the platform safety ceiling. | Add a supervisor-owned lease checked only by the Auto-Pick admission gate. PR continuation and recovery remain eligible. The lease expires automatically, may be revoked early by an authorized operator, never changes the user's scheduler setting, and cannot renew itself without a new reviewed policy decision. |

Each action rechecks current rows under lock, uses incident/action/target as its
idempotency key, and writes before/after audit receipts. Account-wide pause,
follow-up-cap mutation, queue reprioritization, recovery-job enqueueing, and
standing settings changes are rejected for this RDR because existing controls
already own those semantics or the scope is too broad.

Fixed expiry is the fail-safe recovery mechanism for a future lease. A later
healthy semantic finding may recommend early recovery, but Rails does not infer
“meaningful progress” from hard-coded commit/run heuristics. An authorized
operator performs early revocation until a separately reviewed recovery policy
exists.

## Dashboard and Supervisor Health

Open warning/critical incidents appear in an authorized dashboard section
above live metrics and may project blocking human decisions into the existing
Inbox. The notification bell is secondary. Cards contain only sanitized
summary/evidence, affected entity links, current lifecycle, action/lease status,
and required operator decision.

Operators can see the last attempted and successful observation, snapshot
schema/policy version, and a typed failure category. Raw errors are excluded.
Health incidents dedupe and rate-limit so a supervisor outage cannot create an
alert storm.

## Rollout Guard

The named guard is `operational_supervisor_mode`, read through Paid's persisted
account settings and enforced at both scheduling and action dispatch.

- **Default:** `off`; no snapshot, LLM call, incident, or action is produced.
- **Shadow enablement:** an account owner selects `shadow` for an allowlisted
  account after the RDR and LID artifacts merge. Shadow may build snapshots,
  call `agent_harness`, and publish incidents, but action dispatch rejects every
  mutating action.
- **Promotion evidence:** privacy-contract tests pass; malformed/stale output
  is non-mutating; incident precision and operator usefulness are reviewed over
  a declared sample; supervisor cost, latency, and health are measured; and no
  unresolved critical safety finding remains. Numerical promotion targets must
  be approved before the pilot, not chosen after observing results.
- **Mitigation enablement:** requires a reviewed RDR amendment, account-owner
  grant, project opt-in, and a mode beyond `shadow` that names each enabled
  action. No action ships merely because #4713 exists.
- **Rollback:** set mode to `off` to stop new scheduling and action dispatch.
  Revoke active leases through the recorded recovery path; retain incidents and
  audit receipts according to policy.
- **Cleanup:** after a reviewed stable period, remove temporary pilot account
  allowlists and shadow instrumentation that is not part of the accepted health
  contract. Removing the `off` mode or changing the default requires a new
  decision; it is not routine cleanup.

## Measurable Acceptance

The initial observation release is acceptable only when tests and rollout
evidence show that:

- the typed snapshot serializer rejects every forbidden field fixture and the
  exact request captured at the `agent_harness` boundary contains none;
- metric fixtures reproduce declared cohort numerators, denominators, windows,
  and unavailable-source behavior;
- malformed, unknown, stale, cross-account, and uncited findings create no
  delivery mutation;
- repeated equivalent findings reconcile to one incident with first/last-seen
  evidence and tenant-scoped authorization;
- `off` schedules no analysis, `shadow` cannot dispatch a mutation, and rollback
  stops new work while preserving audit evidence;
- authorized operators see urgent incidents and last supervisor health above
  live metrics without an external notification service;
- the final audit verifies shipped code, tests, documentation, production
  guard state, and any enabled action's precondition/expiry/recovery evidence.
  Closed child issues are not sufficient evidence.

## Implementation Tree and Dependencies

The canonical tree is:

- #4708 — epic; Tracks #4341 without closing it
- #4709 — incident and audit persistence; Depends on #4341
- #4710 — snapshot and metric contract; Depends on #4341
- #4711 — `agent_harness` analysis; Depends on #4709 and #4710
- #4712 — default-off/shadow scheduling and incident surface; Depends on #4709
  and #4711
- #4713 — held post-shadow mitigation evaluation; Depends on #4712 and requires
  a reviewed amendment before any implementation
- #4714 — terminal evidence audit; Depends on #4712 and #4713 and Tracks #4708
  without closing it

All implementation issues remain under the `planning` hold until #4341's RDR
and LID artifacts are accepted and merged. The terminal audit leaves final
umbrella acceptance to verified evidence and must file blockers for remaining
gaps.

## Explicit Unresolved Decisions

Normal design review must resolve these before the corresponding phase starts:

1. Approve or replace the proposed 30-day snapshot retention and the maximum
   future admission-lease ceiling based on operational and privacy needs.
2. Predeclare the shadow pilot sample and promotion targets before enablement.
3. After shadow evidence, decide whether either held candidate action earns an
   RDR amendment. The valid decision may be to retain observation-only mode.
4. Decide whether blocking supervisor incidents enter Inbox immediately or
   only after operator calibration demonstrates acceptable precision.

These are not delegated to an implementing agent. No unresolved decision
permits a more permissive default.

## Consequences

Positive consequences are a durable system-level delivery-health view, a
strictly testable privacy boundary, and semantic pattern recognition without
direct mutation authority. Reusing notification projection, audit, Auto-Pick,
queue, and guardrail primitives avoids competing control planes.

Costs include new incident/snapshot storage, an operational component that
needs its own health signal, LLM cost in explicitly enabled shadow accounts,
and deliberate delay before any mitigation can be considered. Sanitization
removes contextual diagnosis data by design, so ambiguous incidents still
require humans.
