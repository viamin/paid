# EARS Specs: Apple Verification Workers

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **APPLE-VERIFY-001** — When an operator publishes an Apple verification
  image, the system SHALL persist its immutable digest, macOS and Xcode
  versions/builds, SDKs, Simulator runtimes, executor version, resource
  envelope, network capability, dedicated GUI-account posture, and smoke-test
  result plus an HTTPS guest-executor endpoint.
  *Tests:* `spec/models/apple_verification_image_spec.rb`.
  *Code:* `AppleVerificationImage`.

- [x] **APPLE-VERIFY-002** — When an Apple verification image is promoted,
  deprecated, retired, or revoked, the system SHALL enforce the documented
  lifecycle transition, require a future retirement time while deprecating an
  image, and require a passing smoke test before promotion;
  only active images SHALL be schedulable for new work.
  *Tests:* `spec/models/apple_verification_image_spec.rb`.
  *Code:* `AppleVerificationImage`.

- [x] **APPLE-VERIFY-003** — When a guest receives a verification job, it
  SHALL accept only protocol version 1 typed operations from the approved
  vocabulary with only that operation's defined payload fields and SHALL reject
  unknown manifest, operation, or payload fields, malformed payloads, and
  arbitrary shell-text fields.
  *Tests:* `spec/lib/apple_verification/guest_protocol_spec.rb`.
  *Code:* `AppleVerification::GuestProtocol`.

- [x] **APPLE-VERIFY-004** — When a capture operation fails, the guest result
  SHALL classify the failure as launch, readiness, action, selection, or export
  and SHALL retain the selected platform and capture target.
  *Tests:* `spec/lib/apple_verification/guest_protocol_spec.rb`.
  *Code:* `AppleVerification::GuestProtocol`.

- [x] **APPLE-VERIFY-005** — When Apple verification work is submitted for a
  feature-enabled project with a control-plane-selected immutable image digest,
  the control plane SHALL select only that account's active image matching the
  digest and dispatch only a protocol-valid manifest through the provider-owned
  authenticated guest connection to that image's HTTPS guest executor;
  disabled projects and accounts without a matching active image SHALL not
  dispatch work, and missing credentials or an executor authentication failure
  SHALL fail without accepting the job.
  *Tests:* `spec/services/apple_verification/execute_guest_job_spec.rb`,
  `spec/lib/apple_verification/guest_connection_spec.rb`.
  *Code:* `AppleVerification::ExecuteGuestJob`,
  `AppleVerification::GuestConnection`.
