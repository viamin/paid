# LLD: Post-Deploy Measurements

```yaml
parent: operator-inbox
prefix: POST-DEPLOY
```

## Problem

Some closeout acceptance criteria are statements about Paid's own live,
deployed data — for example #4812's final acceptance: the 36 closed
planning-hold requests must no longer be actionable in the production Inbox
after the fix deploys. A development snapshot cannot establish that result, a
merged PR is not proof of it, and the performance-measurement workflow
(#4894) explicitly excludes live-data checks. Until now the only
representation was a human Action Required item asking an operator to run and
record a count — fabricating an evidence task precisely because no trusted
collection path existed.

This segment owns that collection path: reviewed, allowlisted, read-only,
bounded checks that Paid runs itself against the authorized project's live
data after the target revision is deployed, recording inspectable closeout
evidence and feeding it into the existing criterion/evidence and
partial-closeout reconciliation path.

## Boundaries

- #4894 owns isolated before/after performance benchmarks (browser recipes,
  benchmark sidecars). This segment never runs repository code or benchmarks;
  its checks are host-side, read-only SQL-count measurements over Paid's own
  tables.
- #4223 owns pre-Inbox classification of agent-actionable work.
- #4641 owns evidence/occurrence reconciliation. This segment reuses those
  contracts (`PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE`,
  `PrerequisiteOccurrences`, evidence submissions) rather than inventing a
  parallel evidence store.
- Planning-hold semantics (`AgentPlanningHolds::*`) own *why* those
  notifications exist; the check here only counts them.

## Design

### Allowlisted checks (`PostDeployMeasurements::Registry`)

A check is a code-reviewed Ruby object registered with a stable `key`, an
integer `version` (the query/check semantics revision), the exact criterion
it measures, the expected `baseline` (recorded for interpretation only —
never success evidence), the `target` count that satisfies the criterion, the
capabilities it requires, and a measurer responding to `measure(project:)`.
The registry is the only input surface: there is no operator-supplied SQL, no
free-text command, and no configuration path that can introduce a new check
without a code review. An unknown key or stale version is rejected as
`unknown` with a named recovery action, never guessed.

### The #4812 check (`Checks::PlanningHoldNotifications`)

`key: "planning_hold_notifications_actionable"`, `version: 1`,
`baseline: 36`, `target: 0`. It counts, within one account and one project
scope, the active (`resolved_at`/`dismissed_at` null) notifications with
source `agent_planning_hold_reconciliation` whose subject issue is closed —
distinguishing `Issue` subjects from `AgentRun` subjects resolved through
their issue — and reports `actionable_closed_source`, `active_open_source`,
`active_total`, and `resolved_total` alongside the project/account scope.
The total and scope travel with the count so a zero is interpretable: a zero
over an empty scope is visibly different from a zero over 36 resolved rows.

### Evidence records (`PostDeployMeasurement`)

`post_deploy_measurements` is a tenant-scoped RLS table, one idempotent row
per `(issue, check_key, check_version, deployed_revision)`. Pending rows hold
the empty-string revision sentinel; execution stamps the deployed revision.
Retries and duplicate events converge on the same row (attempts counter);
a new deployment revision or check version produces a new row so history is
never overwritten, and growth is bounded by the unique key (retention: rows
are evidence history, pruned only with their issue by FK cascades). Rows
carry account/project/issue, criterion text, prerequisite identity binding,
requested_by, status (`pending`, `running`, `awaiting_deployment`, `passed`,
`failed`, `unknown`), deployed revision/pr/deployed_at, executed_at,
duration_ms, counts, details (scope, baseline, target, next action), and
failure_reason.

### Deployment gate (`DeploymentTarget`)

A measurement is only meaningful against the deployed revision. The target
resolves from the issue's terminal closeout evidence: its most recent merged
PR. Revision identity is `pr-<number>@<deployed_at.utc.iso8601>` — stable per
deployment event, so re-marking a deployment invalidates prior evidence
without fabricating a pass. A merged PR not yet marked deployed yields
`awaiting_deployment` (routine, visible, retried by the sweep — never a pass
and never an escalation); no merged PR yields a named recovery action.

### Request entry point

`Projects::PostDeployMeasurementsController#create` is the authorized human
entry: an operator with agent-run authority names an allowlisted check (and
optionally the prerequisite occurrence identity it may release); requesting
never runs the check inline — the bounded sweep owns execution. This replaces
#4812's fabricated "run and record the count" Action Required item: the human
names the check, Paid collects the evidence.

### Execution (`Execute` + jobs)

`PostDeployMeasurementJob` executes one row under the measurement's tenant
context (normal RLS role rules; no bypass, no cross-tenant reads). The
executor probes required capabilities through the tenant read path
(`Capabilities`), resolves the deployment target, then runs the measurer
inside a `SET TRANSACTION READ ONLY` transaction — the database itself
enforces that a check cannot write. Any error classifies as `unknown` with a
failure reason; `failed` is reserved for a real, measured contradiction
(count ≠ target). Attempts are capped (`MAX_ATTEMPTS`); `unknown` rows stay
retry-eligible until the cap, and rows whose target revision moved are
re-requested by the bounded sweep (`PostDeployMeasurementSweepJob`, cron)
while their prerequisite occurrence is still active. Partial results are
never rounded up to a pass: every required count must be present and the
comparison exact.

### Reconciliation (`ReconcileResult`)

A current, passing measurement releases only its matching prerequisite
occurrence: it records a machine-collected evidence submission (outcome
`sufficient`, validator identity `post_deploy_check:<key>:v<version>`,
revision-bound to the occurrence's `source_revision`) on the existing
`partial_closeout.prerequisite` notification, and resolves that notification
only when every occurrence it carries is satisfied — releasing with
`released_by: "post_deploy_measurement"` so the existing re-enqueue and
Inbox-cache refresh fire. It never attests whole-issue completion, never
touches unrelated occurrences, and never bypasses a human decision recorded
by another path.

### Routing and escalation

Routine `pending`/`running`/`awaiting_deployment`/`passed` states surface on
the partial-closeout detail pane (progress and closeout surfaces), not as
Action Required. Escalation is a non-blocking error notification
(`post_deploy_measurement.escalation`) with an exact recommended action, and
is reserved for: missing capability or check definition, authorization
failure at execution, persistent execution failure (attempts exhausted), or a
contradictory (`failed`) result. Following the #4893 precedent, escalation
never fabricates a human evidence task — the measurement request itself is
already machine-owned.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|---|---|---|---|
| Input surface | Code-reviewed registry | Operator-configured SQL/recipes | AC forbids operator-supplied SQL; a review-gated registry is the smallest allowlist that can be trusted with live production reads. |
| Execution place | Host application service under tenant RLS | Container/runner execution of repository code | The measured object is Paid's own database, not repository code; control-plane container execution would blur the boundary #4894 owns and add isolation cost for a COUNT. |
| Read-only enforcement | `SET TRANSACTION READ ONLY` | Convention only (SELECT-only scopes) | The database rejects any write a future check might accidentally introduce; the convention alone cannot. |
| Deployment identity | PR number + `deployed_at` | Merge commit SHA | `issues` carries no merge SHA, but `mark_deployed!`/`deployed_at` is the existing authoritative deployment signal; a re-deployment correctly starts a new evidence generation. |
| Evidence home | Dedicated RLS table + projection into the existing evidence_submissions contract | Notification metadata only; agent-run reconciliation only | The measurement needs its own idempotency key and lifecycle; the prerequisite release must ride the existing occurrence/evidence path so inbox, re-enqueue, and views stay single-sourced. |
| Escalation shape | Non-blocking error notification with exact next action | Blocking Action Required item | The issue's core complaint is fabricated human evidence tasks; routine and recoverable states must not re-create one (#4893 precedent). |
| Post-deploy trigger | Bounded recurring sweep re-evaluating targets | Webhook/enqueue at deploy time only | Deployment marking has no single event source today; the sweep is idempotent, cheap, and also covers retries, attempt caps, and stale revisions. |

## Open Questions & Future Decisions

1. Extending the registry with additional checks (for example other
   tenant-scoped Inbox invariants) — each requires its own reviewed entry,
   version, and focused tests; no generic query surface is planned.
2. A deployment event stream that could replace the polling sweep.

## References

- `docs/intent/partial-closeout-recovery/partial-closeout-recovery-design.md`
  — the criterion/evidence and reconciliation path measurements feed.
- `docs/intent/confidence-driven-delivery/` — planning-hold reconciliation
  semantics the #4812 check counts.
- `docs/intent/page-load-performance/` — #4894's benchmark segment,
  deliberately out of scope here.
