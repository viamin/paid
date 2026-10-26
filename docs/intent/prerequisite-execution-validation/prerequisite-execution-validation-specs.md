# EARS Specs: Prerequisite Execution Validation

- [x] **PREREQUISITE-EXECUTION-001** — When an authorized operator starts a
  technical prerequisite validation from its originating partial-closeout
  Inbox item, Paid SHALL queue one bounded report-only AgentRun with an
  explicit artifact contract for stdout, stderr, exit status, image and
  checkout identity, applicable endpoint response, and cleanup evidence.
  *Code:* `Issues::RequestPrerequisiteExecutionValidation`.
  *Test:* `spec/services/issues/request_prerequisite_execution_validation_spec.rb`.

- [x] **PREREQUISITE-EXECUTION-002** — When preparing prerequisite execution,
  Paid SHALL inspect the selected runner/backend capability interface and
  record the available, required, and missing capabilities; it SHALL not use
  a control-plane Docker socket as evidence that an execution environment is
  unavailable.
  *Code:* `Issues::RequestPrerequisiteExecutionValidation#execution_capabilities`.
  *Test:* `spec/services/issues/request_prerequisite_execution_validation_spec.rb`.

- [x] **PREREQUISITE-EXECUTION-003** — When marketplace tool-sidecar rollout
  is not authorized for the project, Inbox SHALL state the scoped flag/pilot
  setup required and SHALL not enable the flag. The validation run SHALL retain
  normal marketplace attachment, image allowlist, network hardening, budget,
  and cleanup controls.
  *Code:* `dashboard/_inbox_detail_partial_closeout`.
  *Test:* `spec/requests/inbox_spec.rb`.

- [x] **PREREQUISITE-EXECUTION-004** — When an active validation already
  exists for a prerequisite, a repeat action SHALL reuse it rather than queue
  an unchanged duplicate; normal AgentRun cancellation and retry controls
  remain available.
  *Code:* `Issues::RequestPrerequisiteExecutionValidation`.
  *Test:* `spec/services/issues/request_prerequisite_execution_validation_spec.rb`.
