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
  revision-bound result by supplying the attempt's single captured deployment
  revision to the check, retain a new row for a newer deployed revision, and
  record execution failure without fabricating success or retaining a partial
  result as evidence. The operator task SHALL resolve the project and its
  account before establishing tenant context, including from a process with
  no existing tenant context, and SHALL execute the check without system access.
  *Code:* `app/services/trusted_measurements/run_check.rb`,
  `app/jobs/trusted_measurements/run_check_job.rb`,
  `lib/tasks/trusted_measurements.rake`.
  *Test:* `spec/services/trusted_measurements/run_check_spec.rb`,
  `spec/jobs/trusted_measurements/run_check_job_spec.rb`,
  `spec/tasks/rake/task_trusted_measurements_spec.rb`,
  `spec/security/tenant_context_spec.rb`.

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

- [x] **TRUSTED-MEASUREMENTS-007** — When development is the live application
  environment, Paid SHALL identify its mounted checkout by the HEAD commit
  and a digest of tracked and untracked source changes, SHALL change that
  identity when source content changes, and SHALL leave production's explicit
  deployment signal requirement unchanged. An unreadable or unavailable
  checkout SHALL remain unknown rather than become a fabricated revision.
  *Code:* `app/services/trusted_measurements/deployment_signal.rb`.
  *Test:* `spec/services/trusted_measurements/deployment_signal_spec.rb`.

- [x] **TRUSTED-MEASUREMENTS-008** — When a reviewed worker-adoption
  measurement runs in Paid's authorized live environment, it SHALL bind the
  project/account/criterion, environment class, deployment revision, check
  implementation/version, and collection time through the normal allowlisted
  measurement path; it SHALL read only the durable `poll` and `agent`
  readiness observations the owning Temporal worker roles publish about
  themselves into the shared application database — each instance's PID,
  publishing environment, readiness time, raw boot revision, boot-time
  deployment identity, and latest heartbeat. The collector SHALL select only
  observations published by its authorized environment. The evidence
  projection SHALL include every observation that can fall within the freshness
  window and, when none exist for a role, at most its newest stale observation;
  older restart history SHALL NOT be serialized.
  Concurrent process boots for a role SHALL remain independently observable;
  every fresh instance of both roles
  SHALL be complete, timestamp-coherent, refreshed by the live worker's own
  heartbeat within the freshness window, and equal to the deployment revision
  captured for that attempt before the result is successful, while stale
  superseded instances SHALL NOT block adoption. In development, both the persisted
  deployment identity and worker comparison SHALL retain the checkout-content
  fingerprint; a same-HEAD source change after worker boot SHALL remain unknown.
  The Temporal worker SHALL snapshot that complete identity before Rails loads
  application code and verify it after routes, activities, workflows, and
  worker registrations are constructed; when those snapshots differ, it SHALL
  refuse startup before publishing readiness or polling.
  Development and production identity capture SHALL work from the real worker
  entrypoint before Rails or Active Support is loaded.
  The updater-facing raw boot SHA contract SHALL remain unchanged.
  Missing, malformed, stale,
  incoherent, interrupted, restarted, unauthorized, cross-scope, or
  revision-mismatched observations SHALL remain unknown or failed evidence,
  never a successful pull-only inference. The result SHALL cover effective
  worker adoption only, not model/auth/text success or unrelated acceptance
  criteria, and SHALL NOT accept an operator-controlled host command, path,
  SQL, process arguments, environment, credentials, or a PID probe in another
  role's namespace.
  *Code:* `app/models/worker_readiness_observation.rb`,
  `lib/paid/worker_readiness/heartbeat.rb`,
  `lib/paid/worker_readiness/startup_identity.rb`,
  `lib/paid/worker_readiness.rb`,
  `app/services/trusted_measurements/checks/worker_adoption.rb`,
  `app/services/trusted_measurements/run_check.rb`,
  `bin/temporal_worker`.
  *Test:* `spec/models/worker_readiness_observation_spec.rb`,
  `spec/lib/paid/worker_readiness/heartbeat_spec.rb`,
  `spec/lib/paid/worker_readiness/startup_identity_spec.rb`,
  `spec/services/trusted_measurements/checks/worker_adoption_spec.rb`,
  `spec/services/trusted_measurements/run_check_spec.rb`.
