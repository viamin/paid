# EARS Specs: Apple Verification Attempt Lifecycle

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Identifiers are reserved ahead of the implementation issues (RDR-068
> Phase 0); the `Tests:` and `Code:` surfaces below are the ones those issues
> will add.

- [x] **APPLE-ATTEMPT-001** — When an Apple verification attempt is submitted,
  the system SHALL admit it only when the active-VM limit and the host disk,
  host memory, and guest disk thresholds are satisfied, with
  operator-configurable defaults of one active Apple verification VM, 60 GiB
  minimum free host disk before clone, 25% minimum free system memory, and
  15 GiB minimum free guest disk, and SHALL refuse admission during sustained
  critical memory pressure.
  *Tests:* `spec/services/apple_verification_attempts/admission_spec.rb`
  *Code:* `AppleVerificationAttempts::Admission`

- [x] **APPLE-ATTEMPT-002** — While an Apple verification attempt runs, the
  system SHALL recheck host disk and memory thresholds; crossing a normal
  admission threshold SHALL stop new admissions, and a running attempt SHALL
  be terminated only for an actual host-safety condition.
  *Tests:* `spec/services/apple_verification_attempts/admission_spec.rb`
  *Code:* `AppleVerificationAttempts::Admission`

- [x] **APPLE-ATTEMPT-003** — When the active Apple worker slot is occupied,
  attempts SHALL queue fairly by account and project, expose queue position,
  and remain cancellable while queued; operator-configurable limits SHALL
  bound queue depth, runtime, retry count, retained storage, and attempts per
  agent run.
  *Tests:* `spec/services/apple_verification_attempts/queue_spec.rb`,
  `spec/services/apple_verification_attempts/dispatcher_spec.rb`
  *Code:* `AppleVerificationAttempts::Queue`,
  `AppleVerificationAttempts::Dispatcher`, `AppleVerificationDispatchJob`

- [x] **APPLE-ATTEMPT-004** — When an attempt exceeds the configured attempt
  timeout (default 45 minutes), the system SHALL end it in the `timed_out`
  state, and a capacity exhaustion or timeout outcome SHALL be reported as an
  infrastructure result, never as a code failure.
  *Tests:* `spec/services/apple_verification_attempts/timeout_monitor_spec.rb`
  *Code:* `AppleVerificationAttempts::TimeoutMonitor`

- [x] **APPLE-ATTEMPT-005** — Before reserving worker capacity, the system
  SHALL validate project approval, workflow state, source identity,
  capabilities, policy, and quota, and SHALL fail the attempt with a
  `project_configuration` or `unsupported_capability` classification instead
  of provisioning.
  *Tests:* `spec/services/apple_verification_attempts/validate_spec.rb`
  *Code:* `AppleVerificationAttempts::Validate`

- [x] **APPLE-ATTEMPT-006** — When an attempt finishes uploading its output
  manifest and artifacts, the system SHALL revoke the attempt's credentials
  and disable its network authority before recording a terminal state; a
  successful attempt's VM SHALL be destroyed immediately, and a failed
  attempt's VM SHALL be retained for at most the configured window (default
  one hour) with credentials revoked and networking disabled, and SHALL be
  destroyable earlier on request.
  *Tests:* `spec/services/apple_verification_attempts/complete_spec.rb`
  *Code:* `AppleVerificationAttempts::Complete`

- [ ] **APPLE-ATTEMPT-007** — When an attempt verifies committed source, the
  system SHALL supply the exact commit identity and a short-lived read-only
  repository credential through Paid's credential lane, and that credential
  SHALL NOT be stored in repository configuration, artifacts, VM images, or
  host-service arguments.
  *Tests:* `spec/services/apple_verification_attempts/committed_source_spec.rb`
  *Code:* `AppleVerificationAttempts::CommittedSource`

- [ ] **APPLE-ATTEMPT-008** — When an attempt verifies uncommitted source, the
  system SHALL create a content-addressed workspace bundle that excludes
  credentials, caches, derived data, build outputs, and forbidden artifacts,
  passes the existing secret and artifact safety checks, records a manifest
  and content digest, and transfers through Paid's artifact lane without a
  host bind mount; the guest SHALL verify the bundle digest before execution,
  and the bundle SHALL be deleted after the attempt and retry window while
  its digest, safe manifest, and provenance are retained.
  *Tests:* `spec/services/apple_verification_attempts/uncommitted_bundle_spec.rb`
  *Code:* `AppleVerificationAttempts::UncommittedBundle`

- [x] **APPLE-ATTEMPT-009** — Each terminal attempt SHALL classify its failure
  within the closed taxonomy of `project_configuration`, `compile_or_link`,
  `test_assertion`, `launch_or_ui_flow`, `required_capture`,
  `network_policy`, `unsupported_capability`, `capacity_or_quota`,
  `worker_infrastructure`, and `cancellation_or_timeout`, and SHALL reject
  classifications outside it.
  *Tests:* `spec/services/apple_verification_attempts/failure_classification_spec.rb`
  *Code:* `AppleVerificationAttempts::FailureClassification`

- [x] **APPLE-ATTEMPT-010** — The system MAY retry safe infrastructure
  failures within policy and SHALL NOT silently retry deterministic project
  failures or represent an infrastructure failure as a code defect.
  *Tests:* `spec/services/apple_verification_attempts/retry_policy_spec.rb`
  *Code:* `AppleVerificationAttempts::RetryPolicy`

- [x] **APPLE-ATTEMPT-011** — When an approved required workflow assigned to
  the `completion_verification` gate has not succeeded for an agent run that
  reports a committed result, the system SHALL block that agent run from
  reporting success; it SHALL not block a completion without a result commit.
  When assigned to the `pull_request_verification` gate, it SHALL block Paid's
  PR verification result; enforcement SHALL bind the approved committed
  workflow digest and its approved lifecycle gate.
  *Tests:* `spec/services/apple_verification_attempts/gate_enforcement_spec.rb`
  *Code:* `AppleVerificationAttempts::GateEnforcement`,
  `AgentRun#complete!`, `AgentRuns::VerificationResultRecorder`

- [x] **APPLE-ATTEMPT-012** — A draft workflow revision or advisory check
  SHALL NOT block agent completion or PR verification, and a missing or failed
  capture SHALL block only when the approved revision marks it required and
  assigns it to the current lifecycle gate.
  *Tests:* `spec/services/apple_verification_attempts/gate_enforcement_spec.rb`
  *Code:* `AppleVerificationAttempts::GateEnforcement`

- [x] **APPLE-ATTEMPT-013** — Required verification SHALL remain pending until
  it runs or is explicitly waived, and the system SHALL NOT silently skip
  required verification or fall back to executing project code on the
  macOS host. Required-verification enforcement SHALL bind to the commit
  being completed when a result commit is present: a successful attempt on a
  different commit SHALL NOT satisfy the gate. A completion without a result
  commit SHALL not be withheld. A withheld run SHALL be re-invoked via
  `AppleVerificationAttempts::CompleteWithheldRun` by the waive flow,
  by attempt-completion code when it records a `succeeded` attempt, and by
  a 5-minute maintenance sweep so the run still completes when the gate
  later relaxes without any of the synchronous callers firing.
  *Tests:* `spec/services/apple_verification_attempts/gate_enforcement_spec.rb`,
  `spec/services/apple_verification_attempts/complete_withheld_run_spec.rb`,
  `spec/services/apple_verification_attempts/waive_spec.rb`,
  `spec/jobs/apple_verification_withheld_run_sweep_job_spec.rb`,
  `spec/models/agent_run_spec.rb`
  *Code:* `AppleVerificationAttempts::GateEnforcement`,
  `AgentRun#complete!` (withheld marker + payload),
  `AgentRun.awaiting_completion_verification` (stale-running exemption),
  `AppleVerificationAttempt` (succeeded transition),
  `AppleVerificationAttempts::CompleteWithheldRun`,
  `AppleVerificationAttempts::Waive`,
  `AppleVerificationWithheldRunSweepJob`

- [x] **APPLE-ATTEMPT-014** — After a control-plane restart, host restart,
  network interruption, timeout, or partial provisioning failure, lifecycle
  operations SHALL converge idempotently to a known external-resource ledger
  state; unknown or orphaned Paid-owned VMs SHALL be quarantined or destroyed
  according to ledger state and SHALL NOT be adopted as healthy without
  validation.
  *Tests:* `spec/services/apple_verification_attempts/recovery_spec.rb`
  *Code:* `AppleVerificationAttempts::Recovery`

- [x] **APPLE-ATTEMPT-015** — Repeated Apple worker health failures SHALL
  quarantine the worker, revoke its active credentials, and stop scheduling
  against it; a quarantined worker SHALL NOT receive work until an operator
  passes the isolation smoke test and explicitly returns it to service.
  *Tests:* `spec/services/apple_verification_attempts/worker_health_spec.rb`
  *Code:* `AppleVerificationAttempts::WorkerHealth`
