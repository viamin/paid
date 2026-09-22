# EARS Specs: Apple Verification Live Validation

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **APPLE-LIVE-001** — The live-validation suite SHALL map every
  #3978 acceptance criterion to at least one uniquely identified
  scenario carrying its criterion, group, and expected outcome.
  *Tests:* `spec/services/apple_verification/live_validation/suite_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Suite`
- [x] **APPLE-LIVE-002** — When a functional scenario executes, the
  system SHALL run it as repeated clean clones — provisioning a fresh
  VM for each repeat, dispatching a `GuestProtocol`-valid manifest,
  destroying the VM, and asserting an empty inventory before the next
  repeat — and SHALL record per-repeat evidence whose status is passed
  only when every observed operation succeeded.
  *Tests:* `spec/services/apple_verification/live_validation/runner_spec.rb`,
  `spec/services/apple_verification/live_validation/functional_manifests_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Runner`,
  `AppleVerification::LiveValidation::FunctionalManifests`
- [x] **APPLE-LIVE-003** — When an adversarial network probe (direct
  IP, alternate DNS, proxy override, unsupported protocol) is executed
  against the run's resolved guest contract, the system SHALL deny it
  through the shipped audited validator, record the denial reason and
  the created security/audit event references as evidence, and SHALL
  permit a compliant control request built from an allowed destination's
  own port and scheme (never hardcoded 443/https defaults that the
  contract would reject).
  *Tests:* `spec/services/apple_verification/live_validation/network_probes_spec.rb`
  *Code:* `AppleVerification::LiveValidation::NetworkProbes`
- [x] **APPLE-LIVE-004** — An isolation scenario SHALL record live
  evidence only through a configured guest-diagnostics provider and
  SHALL record a gap naming the missing provider otherwise; the harness
  SHALL NOT execute shell text against the guest.
  *Tests:* `spec/services/apple_verification/live_validation/runner_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Runner`
- [x] **APPLE-LIVE-005** — When a recovery scenario converges, the
  system SHALL first move its validating run out of the
  capacity-in-flight set (mirroring the production cancellation lane),
  because the shipped reconciler never claims a resource whose run is
  still in flight, and SHALL assert the terminal ledger state through
  the shipped lifecycle and reconciliation surfaces — observing the
  lane's outcome rather than forcing the ledger to deleted. A recovery
  mechanism the control plane does not provide SHALL be recorded as a
  gap naming the missing surface rather than failed or skipped.
  *Tests:* `spec/services/apple_verification/live_validation/runner_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Runner`
- [x] **APPLE-LIVE-006** — When the capacity scenario executes, the
  system SHALL sample host free disk, free memory, active Apple VMs,
  and concurrent paid-agent containers, SHALL compare every complete
  sample (degraded samples missing a figure are excluded) against the
  RDR-068 admission defaults, and SHALL pass only with at least three
  agent containers active, recording the measured figure; when no
  complete sample exists the scenario SHALL record a gap, never raise.
  *Tests:* `spec/services/apple_verification/live_validation/runner_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Runner`
- [x] **APPLE-LIVE-007** — The rendered report SHALL mark a criterion
  satisfied only when at least one scenario exists for it and every
  scenario passed on a live run, SHALL mark it unmet otherwise with the
  recorded reason, and SHALL include per-group evidence rows and a gap
  section for the next RDR-068 closeout.
  *Tests:* `spec/services/apple_verification/live_validation/report_spec.rb`
  *Code:* `AppleVerification::LiveValidation::Report`
