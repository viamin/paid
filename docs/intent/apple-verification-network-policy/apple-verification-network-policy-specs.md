# EARS Specs: Apple Verification Guest Network Policy

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> These three specs cover the declarative policy layer only — resolving a
> snapshot, building a contract from it, and validating a candidate request
> against that contract. They do not require a running guest and are fully
> testable today. The Tart/Softnet host lifecycle that would actually admit a
> guest and install this contract on it belongs to #3933 and remains a
> separate, not-yet-implemented concern (see the design doc's Rollout
> section) — no guest is exposed or admitted by this segment.

- [x] **APPLE-NETWORK-001** — When resolving an Apple verification guest's
  network policy, the system SHALL resolve and persist the existing per-run
  egress snapshot with a proxy-restricted policy and SHALL produce a
  provider-neutral, credential-free guest enforcement contract only when
  `apple_verification_workers` is enabled for the project; otherwise it
  SHALL raise without persisting or producing a contract.
  *Tests:* `spec/services/agent_runs/apple_verification/resolve_guest_contract_spec.rb`
  *Code:* `AgentRuns::AppleVerification::ResolveGuestContract`,
  `AgentRuns::AppleVerification::GuestContract`

- [x] **APPLE-NETWORK-002** — The guest contract SHALL require Paid DNS and
  Paid proxy routing, deny a direct external route and host services, and
  permit only HTTP(S) destinations that match the resolved snapshot, including
  any destination port and scheme restriction; direct IPs, alternate DNS,
  proxy overrides, and unsupported protocols SHALL be rejected.
  *Tests:* `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb`
  *Code:* `AgentRuns::AppleVerification::ValidateGuestRequest`,
  `AgentRuns::AppleVerification::GuestNetworkRequest`

- [x] **APPLE-NETWORK-003** — A denied Apple guest request SHALL emit safe
  destination and policy-decision audit metadata without credentials or
  payload bodies and SHALL raise a failure whose category is
  `network_policy`.
  *Tests:* `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb`
  *Code:* `AgentRuns::AppleVerification::NetworkPolicyError`,
  `AgentRuns::AppleVerification::ValidateGuestRequest`
