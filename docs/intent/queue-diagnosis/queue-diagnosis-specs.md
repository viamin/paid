# EARS Specs: Queue Diagnosis and Stalled-Handoff Recovery

> Testable claims for explaining an empty or unexplained Upcoming Queue and
> for detecting a delivery handoff that stopped progressing (#4619). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r QUEUE-DIAG-001`).

## Diagnostic states

- [x] **QUEUE-DIAG-001** — When the dashboard diagnoses the visible queue,
  the system SHALL derive exactly one primary diagnostic state from the
  canonical candidate scope (`DefaultCandidateSource.eligible_scope`), the
  canonical scheduler scope (`AgentRun.schedulable_queued_with_priority`) and
  the persisted issue rows, choosing among `healthy`, `runnable_not_seeded`,
  `blocked`, `paused` and `unknown` by the precedence
  `unknown` → `runnable_not_seeded` → `blocked` → `paused` → `healthy`. A
  queue with no open work and no eligible candidate SHALL be reported as
  `healthy`, never as a failure.
  *Code:* `Dashboard::QueueDiagnosis#call`, `Dashboard::QueueDiagnosis#state`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-DIAG-002** — When the dashboard diagnoses the visible queue,
  the system SHALL report counts that keep candidate eligibility, queued runs,
  running runs, blocked issues and paused issues apart, and SHALL NOT count a
  queued or running run's issue as an eligible candidate — an issue with work
  in flight is excluded from the candidate scope by the "work in flight"
  guard.
  *Code:* `Dashboard::QueueDiagnosis#project_counts`,
  `Dashboard::QueueDiagnosis#counts`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-DIAG-003** — When the dashboard diagnoses the visible queue,
  the system SHALL report issue-level blocker provenance for blocked issues,
  listing every simultaneous blocker (never only the first), the work or
  decision that owns each blocker, the last successful stall assessment for
  that issue, and the next supported action for each blocker.
  *Code:* `Issues::QueueBlockers#call`, `Issues::QueueBlockers::Blocker`.
  *Test:* `spec/services/issues/queue_blockers_spec.rb`,
  `spec/services/dashboard/queue_diagnosis_spec.rb`.

## Stalled delivery handoffs

- [x] **QUEUE-DIAG-004** — When a bounded periodic sweep and the relevant
  lifecycle events run, the system SHALL identify non-progressing delivery
  handoffs using only mechanical conditions — an eligible candidate with no
  queued or running run, a recorded confidence-driven planning hold that has
  not changed for the stale window, and terminal delivery evidence with no
  run, no continuation request and no candidate eligibility — and SHALL
  invoke the existing recovery services (`Issues::EnqueueEligible`,
  `FeatureIntents::ReleaseIssue`, `PartialCloseouts::ReconcileLegacy`) within
  their own delegated authority.
  *Code:* `QueueStalls::Detector#call`, `QueueStalls::Recovery#call`,
  `QueueStalls::Sweep#call`, `QueueStalls::SweepJob`.
  *Test:* `spec/services/queue_stalls/sweep_spec.rb`,
  `spec/jobs/queue_stalls_sweep_job_spec.rb`.

- [x] **QUEUE-DIAG-005** — When a stall is assessed, the system SHALL record
  the assessment with the reason code, a digest of the relevant state and
  revisions, the outcome and the assessment time, and SHALL NOT repeat the
  recovery for an unchanged state: a repeated assessment of the same
  `(issue, reason, state digest)` SHALL be recorded as already assessed and
  SHALL NOT invoke the recovery service again. A changed blocker set SHALL
  produce a new digest and SHALL be assessed again.
  *Code:* `QueueStallAssessment`, `QueueStalls::Recovery#assess`,
  `QueueStalls::Detector#state_digest`.
  *Test:* `spec/services/queue_stalls/sweep_spec.rb`,
  `spec/models/queue_stall_assessment_spec.rb`.

- [x] **QUEUE-DIAG-006** — When a recovery fails or keeps failing for the
  same state, the system SHALL bound the attempts, SHALL record the failure
  with its error, and SHALL surface the issue for a human instead of retrying
  forever. The sweep SHALL bound the number of stalls and the number of
  semantic recoveries per invocation and SHALL NOT stack overlapping sweeps.
  *Code:* `QueueStalls::Recovery#call`, `QueueStalls::Sweep#call`,
  `QueueStalls::SweepJob`.
  *Test:* `spec/services/queue_stalls/sweep_spec.rb`,
  `spec/jobs/queue_stalls_sweep_job_spec.rb`.

- [x] **QUEUE-DIAG-007** — When a diagnosis requires semantic repository
  assessment, the system SHALL use the existing `agent_harness` recovery path
  (`PartialCloseouts::ReconcileLegacy`) and SHALL NOT perform an LLM call,
  repository execution or remote mutation while rendering the dashboard.
  *Code:* `QueueStalls::Recovery#recover_unresolved_delivery`,
  `Issues::QueueBlockers#call`, `Dashboard::QueueDiagnosis#call`.
  *Test:* `spec/services/queue_stalls/sweep_spec.rb`,
  `spec/services/dashboard/queue_diagnosis_spec.rb`.

## Human decisions and duplicate work

- [x] **QUEUE-DIAG-008** — When a stall is owned by a human decision
  (manual review, needs-input, an approval-gated feature), the system SHALL
  surface it through the existing actionable Inbox lane that owns that
  decision and SHALL NOT create a second Inbox item, a duplicate follow-up
  issue, or a repeated no-change audit for a state it already assessed.
  *Code:* `QueueStalls::Recovery#call`, `Dashboard::QueueDiagnosis#call`.
  *Test:* `spec/services/queue_stalls/sweep_spec.rb`,
  `spec/services/dashboard/queue_diagnosis_spec.rb`.

## Failure semantics

- [x] **QUEUE-DIAG-009** — When the diagnosis cannot be computed, or when no
  visible project's issue coverage is known, the system SHALL report the
  `unknown` diagnostic state with a recovery action and SHALL NOT treat the
  failure as proof that no work exists. A failed query or a failed issue sync
  SHALL produce unknown coverage rather than an empty count.
  *Code:* `Dashboard::QueueDiagnosis#call`, `Dashboard::QueueDiagnosis#coverage`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

## Freshness

- [x] **QUEUE-DIAG-010** — When the dashboard renders the diagnosis, the
  system SHALL carry the server-side generation time of the snapshot it
  rendered and SHALL mark the tile when a refresh fails, so content that is
  stale or disconnected can never appear current. A tile refresh SHALL
  reflect the current backend queue contents even when the previously
  rendered tile was empty.
  *Code:* `Dashboard::QueueDiagnosis#call`,
  `app/views/dashboard/_queue_diagnosis.html.erb`,
  `app/javascript/controllers/dashboard_frames_controller.js`.
  *Test:* `spec/requests/dashboard_spec.rb`,
  `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

## Boundaries

- [x] **QUEUE-DIAG-011** — When the diagnosis or the recovery runs, the
  system SHALL respect project visibility, tenant boundaries, operating
  profiles and phases, deliberate pauses and the normal admission controls.
  Empty-queue recovery SHALL NOT remove planning labels wholesale and SHALL
  NOT override rollout or approval policy.
  *Code:* `Dashboard::QueueDiagnosis#visible_projects`,
  `Issues::QueueBlockers#call`, `QueueStalls::Recovery#call`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`,
  `spec/services/queue_stalls/sweep_spec.rb`.

- [x] **QUEUE-DIAG-012** — When the diagnosis or the recovery runs for one
  account, it SHALL NOT read or write another account's projects, issues,
  runs or assessments.
  *Code:* `Dashboard::QueueDiagnosis#visible_projects`,
  `QueueStallAssessment` (row-level security), `QueueStalls::Sweep#call`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`,
  `spec/services/queue_stalls/sweep_spec.rb`.
