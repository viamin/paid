# EARS Specs: Apple Verification Guest Network Policy

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **APPLE-NETWORK-001** — When resolving an Apple verification guest's
  network policy, the system SHALL resolve and persist the existing per-run
  egress snapshot with a proxy-restricted policy and SHALL produce a
  provider-neutral, credential-free guest enforcement contract only when
  `apple_verification_workers` is enabled for the project; otherwise it
  SHALL raise without persisting or producing a contract.
  *Tests:* `spec/services/agent_runs/apple_verification/resolve_guest_contract_spec.rb`,
  `spec/services/apple_verification/execute_guest_job_spec.rb`,
  `spec/lib/apple_verification/guest_connection_spec.rb`
  *Code:* `AgentRuns::AppleVerification::ResolveGuestContract`,
  `AgentRuns::AppleVerification::GuestContract`,
  `AppleVerification::ExecuteGuestJob`, `AppleVerification::GuestConnection`

- [x] **APPLE-NETWORK-002** — The guest contract SHALL require Paid DNS and
  Paid proxy routing, deny a direct external route and host services, and
  permit only HTTP(S) destinations that match the resolved snapshot, including
  any destination port and scheme restriction; direct IPs, alternate DNS,
  proxy overrides, and unsupported protocols SHALL be rejected.
  *Tests:* `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb`,
  `spec/services/apple_verification/execute_guest_job_spec.rb`,
  `spec/lib/apple_verification/guest_connection_spec.rb`
  *Code:* `AgentRuns::AppleVerification::ValidateGuestRequest`,
  `AgentRuns::AppleVerification::GuestNetworkRequest`,
  `AppleVerification::ExecuteGuestJob`, `AppleVerification::GuestConnection`

- [x] **APPLE-NETWORK-003** — A denied Apple guest request SHALL emit safe
  destination and policy-decision audit metadata without credentials or
  payload bodies and SHALL raise a failure whose category is
  `network_policy`.
  *Tests:* `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb`
  *Code:* `AgentRuns::AppleVerification::NetworkPolicyError`,
  `AgentRuns::AppleVerification::ValidateGuestRequest`
