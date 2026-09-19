# EARS Specs: Apple Verification Workers

- [x] **APPLE-WORKER-001** — When a caller invokes the macOS host lifecycle API,
  the system SHALL authenticate a versioned request and accept only readiness,
  clone, start, inspect, stop, destroy, and Paid-owned inventory operations.
  *Tests:* `spec/services/apple_verification/host_service_spec.rb`
  *Code:* `AppleVerification::HostService`

- [x] **APPLE-WORKER-002** — If a host lifecycle request contains executable
  text, repository or host paths, mounts, or an image outside the configured
  immutable-image allowlist, the system SHALL reject it before provider work.
  *Tests:* `spec/services/apple_verification/host_service_spec.rb`
  *Code:* `AppleVerification::HostService`

- [x] **APPLE-WORKER-003** — When an Apple VM is provisioned, stopped,
  destroyed, or reconciled, the system SHALL use provider-neutral handles,
  persist Paid ownership metadata in the provisioning and external-resource
  ledgers, register a configured cleanup and inventory adapter before recording
  the provisioning intent, make lifecycle retries idempotent by request ID,
  and retain created resources for reconciliation until cleanup succeeds.
  *Tests:* `spec/services/apple_verification/tart_provider_spec.rb`,
  `spec/services/apple_verification/lifecycle_spec.rb`
  *Code:* `AppleVerification::TartProvider`, `AppleVerification::Lifecycle`,
  `AppleVerification::TartRunner`
