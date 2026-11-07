# EARS Specs: Trusted Post-Deploy Measurements

- [x] **TRUSTED-MEASUREMENTS-001** — When Paid persists a trusted measurement
  attempt, it SHALL bind the attempt to one account/project and source issue
  when synchronized, reject an unallowlisted check key, and enforce the same
  tenant isolation at the database boundary.
  *Code:* `app/models/trusted_measurement_attempt.rb`,
  `db/migrate/20261107082941_create_trusted_measurement_attempts.rb`.
  *Test:* `spec/models/trusted_measurement_attempt_spec.rb`,
  `spec/security/tenant_context_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-002** — When the #4812 check runs for a project,
  it SHALL read only active `agent_planning_hold_reconciliation` Issue
  notifications in that project, report the active total, closed-source count,
  baseline 36, target zero, and project scope, and perform no writes.
  *Code:* `app/services/trusted_measurements/checks/planning_hold_reconciliation_closed_count.rb`.
  *Test:* `spec/services/trusted_measurements/checks/planning_hold_reconciliation_closed_count_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-003** — When a named allowlisted check is run,
  Paid SHALL execute it through project tenant context, persist an idempotent
  revision-bound result, retain a new row for a newer deployed revision, and
  record execution failure without fabricating success.
  *Code:* `app/services/trusted_measurements/run_check.rb`,
  `app/jobs/trusted_measurements/run_check_job.rb`.
  *Test:* `spec/services/trusted_measurements/run_check_spec.rb`,
  `spec/jobs/trusted_measurements/run_check_job_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-004** — When deployment identity or the source
  issue is unavailable, or when deployment identity does not equal the target
  revision named by the collection request, Paid SHALL persist an unknown
  attempt with the exact recovery reason and SHALL not execute the read check.
  *Code:* `app/services/trusted_measurements/run_check.rb`,
  `app/services/trusted_measurements/escalate.rb`.
  *Test:* `spec/services/trusted_measurements/run_check_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-005** — When a trusted measurement is current,
  Paid SHALL provide it to the closeout assessment as revision-bound evidence;
  a stale or non-successful attempt SHALL not be represented as current.
  *Code:* `app/services/trusted_measurements/evidence.rb`,
  `app/services/llm/analyze_partial_closeout.rb`.
  *Test:* `spec/services/trusted_measurements/evidence_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-006** — When trusted measurement semantic evidence
  changes, Paid SHALL mark a prior closeout assessment stale and re-enter the
  bounded assessment path; collection timestamps and identical retries SHALL
  NOT create another evidence generation, and only that assessment may release
  the matching prerequisite.
  *Code:* `app/services/partial_closeouts/assessment.rb`,
  `app/services/trusted_measurements/run_check.rb`,
  `app/services/trusted_measurements/evidence.rb`.
  *Test:* `spec/services/partial_closeouts/assessment_spec.rb`,
  `spec/services/partial_closeouts/auto_audit_spec.rb`,
  `spec/services/trusted_measurements/evidence_spec.rb`.
