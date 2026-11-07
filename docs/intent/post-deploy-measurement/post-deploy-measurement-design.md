---
parent: PAID
prefix: POST-DEPLOY-CHECK
---

# Low-Level Design: Trusted Post-Deploy Measurement

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment defines how Paid collects a repeatable, bounded, read-only
> measurement against a project's own live data after a deployment, and how
> that measurement feeds the existing partial-closeout prerequisite path
> instead of asking an operator to run and record the number by hand.

## Context and Design Philosophy

Some acceptance criteria are mechanical counts against a project's own live
data — "how many of these notifications are still active while their source
issue is closed?" — rather than judgment calls. Before this segment, the only
path to answer such a question was a human: query production manually,
paste the number into a comment, and rely on no automated record of what was
run, against which revision, or with what result. A development database
snapshot cannot stand in, because the question is about what actually shipped
to the live tenant, not about the schema or seed data available locally.

This segment gives Paid a narrow, trusted way to answer that class of
question itself: a reviewed, allowlisted, read-only check runs against one
project's live data after its deployment, and the attempt — including a
failure or an unresolved deployment signal — is persisted as inspectable
evidence. The mechanism is deliberately narrow:

- **Allowlisted, not operator-supplied.** A check is a reviewed code change
  (`PostDeployChecks::Registry::ALLOWLIST`), never a string of SQL or a
  caller-chosen query. Paid will not execute arbitrary repository code or
  operator-supplied queries against production.
- **Read-only and bounded.** Every check performs a small, fixed number of
  aggregate reads (e.g. two `COUNT` queries) — never a result set that scales
  with account size, and never a write to the tables it measures.
- **Tenant-scoped, not a database-role bypass.** A check runs against one
  project's own account scope. It does not use `TenantContext.with_system_access`
  itself — the caller (an operator rake task or a future deploy-triggered job)
  establishes tenant context, and the check is additionally guarded against
  running with no tenant context established at all (see Authorization below).
- **Evidence, not attestation.** A passing measurement updates the one
  prerequisite occurrence it names. It never marks an entire GitHub issue or
  epic complete by itself — that remains the existing criterion/evidence and
  partial-closeout reconciliation path's call (`docs/intent/partial-closeout-recovery/`).

## Checks

A check is a small class under `PostDeployChecks::Checks` with:

- `KEY` — the allowlist key, also the `check_key` persisted on evidence rows.
- `VERSION` — bumped whenever the query's meaning changes, so old evidence is
  never silently reinterpreted under new logic (it is superseded, not mutated).
- `.call(project:)` — returns a typed `Result` (a `Data.define`) with enough
  fields that a zero is interpretable (the relevant total alongside the
  narrower count), plus `baseline`/`target` and a `met_target?` predicate.

The first allowlisted check, `Checks::ClosedAgentPlanningHoldReconciliationCount`,
answers #4812 / `CONFIDENCE-DELIVERY-019`'s acceptance criterion: how many
`agent_planning_hold_reconciliation` notifications are still active while
their source issue is closed. Its baseline is the 36 cases recorded in the
development snapshot when the gap was filed; its target is 0. It reports
`active_total` (every active notification of that source for the project)
alongside `active_with_closed_source`, so a `0` is legible as "none of this
project's active holds have a closed source issue" rather than "this project
has no active holds at all."

Adding a check means adding a class and one `Registry::ALLOWLIST` entry — a
reviewed PR, never a runtime-configurable string.

## Deployment Signal

"After the relevant deployment" is supplied, not detected. Paid has no
general webhook-driven "this revision is live in production" signal today.
Two existing, narrower primitives compose into what this segment needs:

- `deployed_revision` — a plain string identifying the live application
  revision, supplied by the caller (the deploy pipeline or an operator),
  mirroring the existing external-supply convention in
  `FeatureIntents::Release`'s `merged_revision` (also caller-supplied, also
  validated only for shape, never self-detected).
- `Issue#deployed_at` / `#deployed?` / `#mark_deployed!` — an existing,
  currently uncalled primitive marking one merged PR issue as having reached
  production. When a check names a `source_issue` (the PR that implemented
  the behavior being measured), `PostDeployChecks::Run` refuses to execute
  until that issue reports `deployed?` — treating an undeployed source as an
  ordinary, self-resolving "not yet" rather than a failure.

Both signals are optional on `Run` — a check with no natural "the PR that
shipped this" issue (there may not be one, or it may predate `deployed_at`
tracking) can still run once an operator supplies `deployed_revision`.

## Idempotent Evidence

`PostDeployCheckRun` persists one row per attempt. Its idempotency key is
`"#{check_key}:v#{check_version}:project#{project_id}:#{deployed_revision}"`,
unique per account. Re-invoking with the same inputs returns the existing row
instead of re-running the check (duplicate deploy-pipeline events, retries
after a transient failure before the row updated, etc. are all idempotent
no-ops once a row has `status: "succeeded"`).

- **Stale deployment revisions.** A new deployed revision is a new
  idempotency key, so it creates a new row rather than mutating the old one.
  Once that new row succeeds, every other current row for the same
  `check_key`/project is marked `superseded_by_id`, so a consumer scoped to
  `PostDeployCheckRun.current` only ever sees the latest succeeded evidence —
  an older revision's result can never be read back as "the" current answer.
- **Retention.** Superseded rows are never deleted or mutated in place —
  supersession is append-only history, inspectable the same way
  `feature_intent_facet_evidence.superseded_by_id` preserves prior evidence.
- **Partial/failed results never fabricate a pass.** `status` is one of
  `pending`, `running`, `succeeded`, `failed`, `unknown` — only a check that
  actually completed its reads reaches `succeeded`; any raised error short of
  that persists `failed` with `failure_reason`, and a blocked deployment
  signal persists `unknown` with its own reason. Neither carries a `result`
  that a caller could mistake for an answer.

## Authorization

A check's own reads are explicit (`Notification.where(account: project.account, ...)`),
so they return the right rows even when Postgres row-level security would
otherwise scope them — explicit `WHERE account_id = ?` does not depend on
session-level tenant state. But RLS enforcement is exactly backwards for
*missing* context: with no tenant context established (no bypass, no current
account), the measured tables' own `tenant_isolation` policies make every
read return zero rows — indistinguishable from a genuinely passing
measurement. `Run#require_authorized_context!` guards against exactly this:
it requires either `TenantContext.bypass_enabled?` (an explicit, intentional
system-level read — the same opt-in `LegacyPartialCloseoutReconciliationSweepJob`
and the `post_deploy_checks:run` rake task use) or `Current.account` to match
the project's own account. Neither held means the context is simply missing,
and `Run` raises rather than silently persisting a zero-looking pass. There is
no tenant-scoped way to record that failure as evidence of itself, so it is
not caught and converted into a `PostDeployCheckRun` row — it propagates to
the caller as a loud, process-boundary failure.

## Escalation

Routine states — `pending`, `running`, a `succeeded` run regardless of
whether its target was met, and an `unknown` run blocked only on a
not-yet-deployed signal — are progress/closeout-surface information, not
Action Required: nothing here requires a human decision Paid cannot make
itself, and each self-resolves (the next scheduled run, or the deployment
actually landing). Two conditions escalate to a blocking `Notification`
instead, following the two-test severity gate in
`docs/intent/notification-severity/`:

- **Immediate, on any non-retryable execution error** (`source:
  "post_deploy_check_execution_failed"`) — a bug in the check, or a database
  capability it needs being unavailable. This cannot self-resolve by waiting;
  retrying the identical code against the identical data will fail the same
  way.
- **After `PERSISTENT_FAILURE_THRESHOLD` (3) consecutive failed attempts**
  for the same check and project (`source:
  "post_deploy_check_persistent_failure"`) — a transient infrastructure error
  (`ActiveRecord::ConnectionNotEstablished`/`ConnectionTimeoutError`) gets
  that many chances to self-resolve on retry before it is treated as
  something a human needs to look at.

Both publish through the existing `Notifications::Publish` with
`metadata.recommended_action` naming the concrete next step, per the
notification-severity segment's Inbox bridge — never a bare "something went
wrong."

## Feeding the Existing Criterion/Evidence Path

`PostDeployChecks::FeedPrerequisiteEvidence` is the bridge into
`docs/intent/partial-closeout-recovery/`'s existing contract. It never
re-derives that contract; it writes the same `evidence_submissions` shape
`PartialCloseouts::SubmitEvidence` / `ValidateSubmittedEvidence` already
use, reads occurrences through the existing `PartialCloseouts::PrerequisiteOccurrences`,
and resolves a notification exactly as `ValidateSubmittedEvidence` does —
only when **every** current occurrence on that notification is sufficient at
its current `source_revision` — except it writes `released_by:
"trusted_measurement"` instead of `"reconciled_evidence"`, added to
`Notification#partial_closeout_prerequisite_released?`'s allowed values
alongside the existing `reconciled_attribution` / `reconciled_evidence` /
`external_prerequisite`.

This only runs when a caller supplies a `notification` and
`prerequisite_identity` — a check can be run purely to collect evidence
(satisfying "verify the live count" on its own) without naming a prerequisite
occurrence to resolve, which matters in this repository because no actual
production `Notification` for #4812 exists for this change to target; wiring
a specific notification/identity is an operator action taken once the real
occurrence exists in production.

A target miss (the check ran and succeeded, but `met_target?` is false) still
records an `insufficient` submission — inspectable progress evidence — and
never resolves the notification. The feed step is idempotent per
`PostDeployCheckRun`: re-feeding the same already-fed run is a no-op rather
than appending a duplicate submission or re-evaluating resolution.

## Decisions & Alternatives

| Decision | Alternative(s) considered | Rationale |
|---|---|---|
| Checks are a compiled Ruby allowlist (`Registry::ALLOWLIST`), not data | A `post_deploy_checks` table of operator-editable query definitions | The acceptance criteria explicitly forbid operator-supplied SQL; a reviewed code change is the only form of "allowlisted" that cannot become an injection or cross-tenant-read vector. |
| `deployed_revision` is caller-supplied | Self-detect from `git rev-parse` at check time, or from a deploy webhook | `git rev-parse` (as `PerformanceBenchmarks::Report` already does) reports the *control plane's* revision, not the measured *project's* deployed revision — those can differ, and webhook-driven deploy detection does not exist in this codebase yet and is out of scope for this segment. External supply mirrors `FeatureIntents::Release`'s existing `merged_revision` convention. |
| Stale evidence is handled by supersession (`superseded_by_id`), not by deleting or mutating old rows | Overwrite the single current row per check+project in place | Retention without fabrication requires that an inspector can always see what actually ran at an older revision; mutating in place would destroy that history, and deleting it would make an old "succeeded" row re-readable as current if a consumer query forgot to filter it, which `current` scoping forecloses structurally. |
| Reuse `evidence_submissions` / `released_by` on the existing prerequisite `Notification` rather than a new resolution model | Have `PostDeployCheckRun` itself carry a `resolved_prerequisite_id` and teach the Inbox a second resolution path | The acceptance criteria require reusing #4641's existing criterion/evidence and partial-closeout reconciliation path, not a parallel one; the existing `all_current_occurrences_sufficient?` / `released_by` contract already expresses exactly "a current, sufficient submission for every occurrence resolves the notification," which is exactly the semantics a trusted measurement should participate in. |
| `require_authorized_context!` is a Ruby-level assertion inside `Run`, not relied on RLS alone | Trust RLS alone to make a missing-context read return nothing, and treat "nothing" as evidence of a pass | A missing context and a genuinely-zero result are indistinguishable at the RLS layer; only an explicit assertion before trusting the read's zero can tell them apart, and this codebase's own database role is a superuser that bypasses RLS entirely in development/test, so RLS cannot be the only enforcement point even operationally. |
| Escalation threshold for transient failures is a fixed `3`, immediate for non-retryable errors | A single fixed threshold for every error class | Transient infrastructure errors are expected to self-resolve on retry (style guide: classify retryable vs non-retryable); a bug or missing capability will not, so waiting three attempts to report it only delays a fix that retrying cannot produce. |

## Open Questions & Future Decisions

- No deploy-triggered job exists yet to call `PostDeployChecks::Run`
  automatically "after the relevant deployment" — today's entry point is the
  `post_deploy_checks:run` rake task, invoked by an operator or a deploy
  pipeline step that already knows the revision it just shipped. Wiring an
  automatic deploy-event trigger is future work, out of scope here.
- Verifying #4812 against the real `viamin/paid` production dataset requires
  running `post_deploy_checks:run` against that live project after this
  change deploys — this repository's own agent-run environment has no path
  to that production database, so this is recorded as the remaining operator
  action rather than claimed as already-verified.
