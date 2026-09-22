# EARS Specs: Apple Worker Operator Setup

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **APPLE-SETUP-001** — When the setup command runs in `--preflight`
  mode, the system SHALL perform only read-only host inspections (no
  host state mutation, no guest execution, no project-code execution) and
  SHALL report, for every check, the precise shell command the operator
  must run when the check fails.
  *Tests:* `spec/services/apple_verification/setup/preflight_spec.rb`
  *Code:* `AppleVerification::Setup::Preflight`
- [x] **APPLE-SETUP-002** — When preflight runs, the system SHALL validate
  macOS virtualization permission (`sysctl kern.hv_vmm_present`),
  Tart binary presence and major version, Softnet reachability, the
  approved immutable image identity (recursive SHA-256 over every
  non-hidden file under `<TART_HOME>/vms/<name>/` matched against the
  full `AppleWorkerProfile#image_digest` — `tart list` does not emit
  digests), the Xcode toolchain and accepted license, installed
  Simulator runtimes, the dedicated non-admin guest GUI account posture,
  host-service authentication via `APPLE_VERIFICATION_HOST_URL`/
  `APPLE_VERIFICATION_HOST_TOKEN`, proxy enforcement, and
  operator-configurable capacity (free disk, free memory, active Apple
  VM count, projected guest disk).
  *Tests:* `spec/services/apple_verification/setup/preflight_spec.rb`,
  `spec/services/apple_verification/setup/shell_spec.rb`
  *Code:* `AppleVerification::Setup::Preflight`,
  `AppleVerification::Setup::Shell`
- [x] **APPLE-SETUP-003** — When the setup command runs in `--smoke` mode,
  the system SHALL exercise only the shipped control-plane boundaries
  (`AppleVerification::Lifecycle`, `AppleVerification::HostService`,
  `GuestProtocol`, `AgentRuns::AppleVerification::ValidateGuestRequest`)
  and SHALL record a `gap` (never `pass`) when an upstream mechanism it
  needs is not yet wired in.
  *Tests:* `spec/services/apple_verification/setup/smoke_tests_spec.rb`
  *Code:* `AppleVerification::Setup::SmokeTests`
- [x] **APPLE-SETUP-004** — The smoke suite SHALL prove permitted
  dependency access (a SwiftPM `package resolve` against an
  allow-listed host returns succeeded without `EgressSecurityEvent`),
  host isolation (every diagnostics probe returns `denied`), build/test
  execution on the `viamin/ColorMatching-iOS` reference scheme through
  `GuestProtocol`, app launch against the smoke iOS app, and macOS app
  screenshot capture, each recorded as `passed` only when the observed
  control-plane outcome matches the expectation.
  *Tests:* `spec/services/apple_verification/setup/smoke_tests_spec.rb`
  *Code:* `AppleVerification::Setup::SmokeTests`,
  `AppleVerification::Setup::Smoke::Manifests`
- [x] **APPLE-SETUP-005** — `AppleVerification::Setup::Plan` SHALL
  translate every preflight gap into a numbered manual operator action
  that names the exact shell command(s), the expected proof of success,
  and the canonical guide section the operator should read first; the
  rendered plan SHALL match the Markdown guide so no independently
  maintained duplicate guide is produced.
  *Tests:* `spec/services/apple_verification/setup/plan_spec.rb`
  *Code:* `AppleVerification::Setup::Plan`,
  `AppleVerification::Setup::Report`
- [x] **APPLE-SETUP-006** — The canonical Markdown operator guide SHALL
  cover initial install, profile updates, deprecation/revocation,
  quarantine and return-to-service, recovery, cleanup, and
  troubleshooting; it SHALL state explicitly that routine project use,
  workflow approval, and verification require no guest login and that
  the first-release setup requires no Apple ID; and the guide SHALL be
  the only Markdown operator guide for this capability so no PDF or
  independently maintained duplicate guide is introduced.
  *Tests:* `spec/requests/apple_verification/setup_guide_spec.rb`
  *Code:* `docs/rdrs/apple-worker-operator-guide.md`
- [x] **APPLE-SETUP-007** — The setup driver (`bin/apple-worker-setup`)
  SHALL exit non-zero when any preflight check is in `gap` state or any
  smoke scenario fails, SHALL print warnings as warnings, and SHALL never
  mutate host state, write to the application database, or shell into
  the guest.
  *Tests:* `spec/bin/apple_worker_setup_spec.rb`
  *Code:* `bin/apple-worker-setup`
