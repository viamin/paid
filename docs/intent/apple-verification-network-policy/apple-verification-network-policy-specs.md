# EARS Specs: Apple Verification Guest Network Policy

- [x] **APPLE-NETWORK-001** — When an Apple verification guest is admitted,
  the system SHALL resolve and persist the existing per-run egress snapshot
  with a proxy-restricted policy and SHALL produce a provider-neutral,
  credential-free guest enforcement contract only when
  `apple_verification_workers` is enabled for the project.
  *Tests:* `spec/services/apple_verification/guest_network_policy_spec.rb`,
  `spec/services/apple_verification/guest_launcher_spec.rb`
  *Code:* `AppleVerification::GuestNetworkPolicy`,
  `AppleVerification::GuestLauncher`, `AppleVerification::GuestProvider`

- [x] **APPLE-NETWORK-002** — The guest contract SHALL require Paid DNS and
  Paid proxy routing, deny a direct external route and host services, and
  permit only HTTP(S) destinations that match the resolved snapshot; direct
  IPs, alternate DNS, proxy overrides, and unsupported protocols SHALL be
  rejected.
  *Tests:* `spec/services/apple_verification/guest_network_policy_spec.rb`
  *Code:* `AppleVerification::GuestNetworkPolicy`

- [x] **APPLE-NETWORK-003** — A denied Apple guest request SHALL emit safe
  destination and policy-decision audit metadata without credentials or
  payload bodies and SHALL raise a failure whose category is
  `network_policy`.
  *Tests:* `spec/services/apple_verification/guest_network_policy_spec.rb`
  *Code:* `AppleVerification::GuestNetworkPolicy`
