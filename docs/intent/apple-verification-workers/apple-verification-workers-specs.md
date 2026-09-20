# EARS Specs: Apple Verification Workers

- [x] **APPLE-WORKER-001** — When a verification request names capabilities or
  platform constraints unsupported by its immutable profile, the system SHALL
  reject it before provisioning and SHALL use provider-neutral capability names.
- [x] **APPLE-WORKER-002** — Input and output manifests SHALL use RDR-057
  transfer lanes with allowlisted fields and SHALL reject host paths, provider
  lifecycle fields, and raw or secret-shaped credential values.
- [x] **APPLE-WORKER-003** — Each project SHALL persist exactly one Apple
  verification mode of `off`, `on_demand`, or `automatic`.
- [x] **APPLE-WORKER-004** — Workflow revisions SHALL have `draft`, `approved`,
  `superseded`, or `disabled` state; only a project administrator MAY approve a
  revision with an active profile, and approval SHALL bind committed content,
  verification files, profile, gate, and required/advisory checks immutably. At
  most one revision per project SHALL be approved at a time.
- [x] **APPLE-WORKER-005** — Each attempt SHALL bind account, project, source,
  workflow, profile, and gate; its profile and gate SHALL match its workflow;
  it SHALL use an explicit lifecycle state; and a draft workflow MAY run only
  at the advisory `agent_iteration` gate, while enforcement gates require an
  approved workflow. An attempt SHALL reject a revoked profile.
- [x] **APPLE-WORKER-006** — A waiver SHALL apply to exactly one attempt and
  SHALL bind its project-administrator actor, reason, expiry, source, workflow,
  gate, and checks.
- [x] **APPLE-WORKER-007** — Audit events and resource-ledger entries linked to
  an Apple attempt SHALL have matching account/project ownership; external VMs
  SHALL use the ledger's `verification_vm` resource kind.
- [x] **APPLE-WORKER-008** — When a caller invokes the macOS host lifecycle API,
  the system SHALL authenticate a versioned request and accept only readiness,
  clone, start, inspect, stop, destroy, and Paid-owned inventory operations.
  *Tests:* `spec/services/apple_verification/host_service_spec.rb`
  *Code:* `AppleVerification::HostService`
- [x] **APPLE-WORKER-009** — If a host lifecycle request contains executable
  text, repository or host paths, mounts, or an image outside the configured
  immutable-image allowlist, the system SHALL reject it before provider work.
  *Tests:* `spec/services/apple_verification/host_service_spec.rb`
  *Code:* `AppleVerification::HostService`
- [x] **APPLE-WORKER-010** — When an Apple VM is provisioned, stopped,
  destroyed, or reconciled, the system SHALL use provider-neutral handles,
  persist Paid ownership metadata in the provisioning and external-resource
  ledgers, register a configured cleanup and inventory adapter before recording
  the provisioning intent, make lifecycle retries idempotent by request ID
  within the resource ownership scope by retrying a failed start from its
  recorded VM while retaining a retryable provisioning ledger state, and retain
  created resources for reconciliation until cleanup succeeds.
  *Tests:* `spec/services/apple_verification/tart_provider_spec.rb`,
  `spec/services/apple_verification/lifecycle_spec.rb`
  *Code:* `AppleVerification::TartProvider`, `AppleVerification::Lifecycle`,
  `AppleVerification::TartRunner`, `ExecutionRunners::ResourceReconciler`
