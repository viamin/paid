# EARS Specs: Runner Zero Data Retention Declaration

## Persistence and provenance

- [x] **RUNNER-ZDR-001** — When a runner is created without an explicit ZDR
  setting, the system SHALL persist `zdr_required` as false, independently of
  the runner's model-selection policy.
- [x] **RUNNER-ZDR-002** — When `zdr_required` is true, the runner's current
  provider resolves to OpenRouter, and Paid's execution adapter sends the ZDR
  routing control, the system SHALL report provenance as `openrouter_enforced`;
  when the adapter does not support that control or the runner resolves to
  another provider, the system SHALL report `user_declared`; and when the
  setting is false, it SHALL report `none`.
- [x] **RUNNER-ZDR-003** — When a runner's provider or credential configuration
  changes, the system SHALL derive ZDR provenance from the current configuration
  without retaining a stale enforcement claim.

## Runtime privacy floor

- [x] **RUNNER-ZDR-004** — When OpenRouter routing is built for a runner that
  requires ZDR, the system SHALL send `zdr: true`; restricted projects SHALL
  continue to send `zdr: true` even when the runner setting is false, and
  confidential or restricted projects SHALL continue to deny data collection.
- [x] **RUNNER-ZDR-005** — When a non-OpenRouter runner requires ZDR, the system
  SHALL accept the user declaration without claiming verified runtime
  enforcement or requiring Paid to verify an external agreement.

## Authorized surfaces

- [x] **RUNNER-ZDR-006** — When an authorized user creates or updates a runner,
  the runner form SHALL accept the ZDR setting and display the guidance “You are
  responsible for verifying this provider's zero data retention agreement and
  configuration.”
- [x] **RUNNER-ZDR-007** — When runner details or serialized runner
  configuration are shown through existing authorized tenant-scoped interfaces,
  the system SHALL expose both `zdr_required` and its derived provenance.
- [x] **RUNNER-ZDR-008** — When a runner is created or updated, the audit event
  SHALL record `zdr_required` and the derived provenance visible at that time.
