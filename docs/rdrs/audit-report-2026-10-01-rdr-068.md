# RDR-068 Re-audit — 2026-10-01

**RDR:** [RDR-068](RDR-068-apple-platform-verification-workers.md)  
**Umbrella:** #3930 (remains open)  
**Decision:** **Partially Implemented**

This re-audit applies the [RDR Closeout Checklist](closeout-checklist.md) to
the current repository. It is evidence from shipped code and tests, not from
the state of child issues.

## Shipped, with focused evidence

| RDR area | Code evidence | Test evidence |
| --- | --- | --- |
| Host isolation and provider lifecycle | `AppleVerification::HostService`, `AppleVerification::TartProvider`, `AppleVerification::Lifecycle` | `spec/services/apple_verification/host_service_spec.rb`, `tart_provider_spec.rb`, `lifecycle_spec.rb` |
| Immutable guest protocol and network policy | `AppleVerification::ExecuteGuestJob`, `AppleVerification::GuestProtocol`, `AgentRuns::AppleVerification::ValidateGuestRequest` | `spec/services/apple_verification/execute_guest_job_spec.rb`, `spec/lib/apple_verification/guest_protocol_spec.rb`, `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb` |
| Scheduling, capacity, timeout, cleanup, and health | `AppleVerificationAttempts::Dispatcher`, `Admission`, `TimeoutMonitor`, `Complete`, `WorkerHealth` | matching specs in `spec/services/apple_verification_attempts/` |
| Approval, gates, UI, and agent tools | `AppleVerificationAttempts::GateEnforcement`, `AppleVerification::AgentTools`, project Apple-verification controller/views | `gate_enforcement_spec.rb`, `spec/lib/apple_verification/agent_tools_spec.rb`, `spec/requests/projects/apple_verifications_spec.rb` |
| Setup and live-validation harness | `bin/apple-worker-setup`, `AppleVerification::Setup::*`, `AppleVerification::LiveValidation::*` | `spec/bin/apple_worker_setup_spec.rb`, `spec/services/apple_verification/setup/`, `spec/services/apple_verification/live_validation/` |

## Required gaps

1. **Approved workflow dispatch is not wired.**
   `AppleVerificationAttempts::Provision#guest_manifest` emits only
   `materialize_source` and `export_artifacts`. It does not parse or retain the
   approved configuration's project/scheme/test-plan/capture declarations, so
   it cannot dispatch the required `build`, `test`, `launch_app`, UI-flow, or
   `capture` operations. `GuestResult` correctly fails such required checks as
   `project_configuration`; `provision_spec.rb` asserts that behavior. This
   leaves functional criteria for iOS, iPadOS, macOS, sequential profiles, and
   build/test-only runs unmet.
2. **Source and result/artifact components are disconnected.**
   `AppleVerification::SourceLane::Build`, `ResultManifest::Build`, and
   `ArtifactIngestion::Ingest` have focused tests, but `Provision` does not
   invoke them. A real attempt therefore cannot transfer an exact committed
   checkout or uncommitted bundle, ingest guest artifacts, or persist the
   validated structured output manifest. The corresponding transfer EARS
   claims are marked open until this production connection exists.
3. **Live acceptance evidence is absent.**
   The live-validation harness is present, but this environment has no
   configured macOS/Tart host or recorded pilot output. It cannot establish
   the repeated clean-clone, host-isolation, network-enforcement, or
   three-container capacity criteria. The rollout guard correctly remains
   default-off.

## Conclusion

No broad rollout, feature-flag cleanup, or epic closure is justified. The
existing design invariants remain valid; the next implementation work must
wire approved configuration, source transport, guest execution, output
ingestion, and cleanup into one attempt path, then collect the required live
macOS evidence before a final closeout.
