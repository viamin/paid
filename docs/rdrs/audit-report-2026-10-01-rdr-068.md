# RDR-068 Re-audit — 2026-10-01

**RDR:** [RDR-068](RDR-068-apple-platform-verification-workers.md)
**Umbrella:** #3930 (remains open)
**Decision:** **Partially Implemented**

This re-audit applies the [RDR Closeout Checklist](closeout-checklist.md) to
the current repository. It is evidence from shipped code and tests, not from
the state of child issues.

## Shipped, with focused evidence

The table below records the shipped code surface for each RDR area. Every row
also names the spec paths that exercise the behavior; per checklist step 1,
the executed counts for the spec paths called out in this audit are recorded
in §Executed test evidence below (not just paths).

| RDR area | Code evidence | Spec paths |
| --- | --- | --- |
| Host isolation and provider lifecycle | `AppleVerification::HostService`, `AppleVerification::TartProvider`, `AppleVerification::Lifecycle` | `spec/services/apple_verification/host_service_spec.rb`, `tart_provider_spec.rb`, `lifecycle_spec.rb` |
| Immutable guest protocol and network policy | `AppleVerification::ExecuteGuestJob`, `AppleVerification::GuestProtocol`, `AgentRuns::AppleVerification::ValidateGuestRequest` | `spec/services/apple_verification/execute_guest_job_spec.rb`, `spec/lib/apple_verification/guest_protocol_spec.rb`, `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb` |
| Scheduling, capacity, timeout, cleanup, and health | `AppleVerificationAttempts::Dispatcher`, `Admission`, `TimeoutMonitor`, `Complete`, `WorkerHealth` | matching specs in `spec/services/apple_verification_attempts/` |
| Approval, gates, UI, and agent tools | `AppleVerificationAttempts::GateEnforcement`, `AppleVerification::AgentTools`, project Apple-verification controller/views | `gate_enforcement_spec.rb`, `spec/lib/apple_verification/agent_tools_spec.rb`, `spec/requests/projects/apple_verifications_spec.rb` |
| Setup and live-validation harness | `bin/apple-worker-setup`, `AppleVerification::Setup::*`, `AppleVerification::LiveValidation::*` | `spec/bin/apple_worker_setup_spec.rb`, `spec/services/apple_verification/setup/`, `spec/services/apple_verification/live_validation/` |
| Source / result / artifact components (unit-only) | `AppleVerification::SourceLane::Build`, `AppleVerification::ResultManifest::Build`, `AppleVerification::ArtifactIngestion::Ingest` | `spec/services/apple_verification/source_lane/`, `spec/services/apple_verification/result_manifest/`, `spec/services/apple_verification/artifact_ingestion/` (see §Executed test evidence) |

## Executed test evidence

Per checklist step 1 ("Confirm the test evidence actually runs and asserts the
behavior — not merely that a spec file exists"), the spec paths named in the
table above for the source / result / artifact components and the attempt
dispatch surface were re-run on 2026-10-01 against the current `main`:

```
$ bundle exec rspec \
    spec/services/apple_verification/source_lane/build_spec.rb \
    spec/services/apple_verification/source_lane/bundle_builder_spec.rb \
    spec/services/apple_verification/source_lane/credential_lane_spec.rb \
    spec/services/apple_verification/result_manifest/build_spec.rb \
    spec/services/apple_verification/artifact_ingestion/ingest_spec.rb \
    spec/services/apple_verification/artifact_ingestion/storage_spec.rb \
    spec/services/apple_verification_attempts/provision_spec.rb \
    spec/services/apple_verification_attempts/guest_result_spec.rb

Finished in 5.17 seconds (files took 2.34 seconds to load)
64 examples, 0 failures
```

Per-file counts:

| Spec file | Examples |
| --- | ---: |
| `spec/services/apple_verification/source_lane/build_spec.rb` | 7 |
| `spec/services/apple_verification/source_lane/bundle_builder_spec.rb` | 11 |
| `spec/services/apple_verification/source_lane/credential_lane_spec.rb` | 12 |
| `spec/services/apple_verification/result_manifest/build_spec.rb` | 4 |
| `spec/services/apple_verification/artifact_ingestion/ingest_spec.rb` | 11 |
| `spec/services/apple_verification/artifact_ingestion/storage_spec.rb` | 8 |
| `spec/services/apple_verification_attempts/provision_spec.rb` | 7 |
| `spec/services/apple_verification_attempts/guest_result_spec.rb` | 4 |
| **Total** | **64** |

This run is the executed evidence behind the §Required gaps finding that the
`Provision#guest_manifest` payload fails the `project_configuration` check when
the approved revision requires build/test/capture work
(`spec/services/apple_verification_attempts/provision_spec.rb`,
`spec/services/apple_verification_attempts/guest_result_spec.rb`): both files
exercise `Provision#call` end-to-end against approved revisions with required
checks, and both pass today, asserting the closed-fail behavior the gap
describes.

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
   `ArtifactIngestion::Ingest` have focused tests (see §Executed test
   evidence), but `Provision` does not invoke them. A real attempt therefore
   cannot transfer an exact committed checkout or uncommitted bundle, ingest
   guest artifacts, or persist the validated structured output manifest. The
   corresponding transfer EARS claims are marked open until this production
   connection exists.
3. **Live acceptance evidence is absent.**
   The live-validation harness is present, but this environment has no
   configured macOS/Tart host or recorded pilot output. It cannot establish
   the repeated clean-clone, host-isolation, network-enforcement, or
   three-container capacity criteria. The rollout guard correctly remains
   default-off.

## Tracker state and required tracker filing

Checklist step 3 requires an open focused tracker for every unmet criterion.
As of this audit date, #3930 is open, but the historical child issues #3936, #3937, and #3978 are closed as completed. Their historical scopes, recorded
in the [2026-09-22 audit](audit-report-2026-09-22-rdr-068.md), clarify the
work that remains, but closed issues cannot serve as auto-pickable owners.
New focused child issues must be filed under #3930 before implementation
continues. This creates one actionable owner per gap without reopening or duplicating
the completed historical work.

| # | Gap | Historical tracker | Current state | Required action |
|---|---|---|---|---|
| 1 | Approved workflow dispatch wiring inside `Provision#guest_manifest` (derives the approved configuration's `build` / `test` / `launch_app` / UI-flow / `capture` operations from the approved revision's project/scheme/test-plan declarations and dispatches them through the guest protocol) | #3936 | Closed 2026-09-26 | File a focused #3930 child issue for the production dispatch path. #3936 documented related scheduler work, but it cannot own this remaining gap. |
| 2 | Source / result / artifact components not invoked from the dispatch path (`SourceLane::Build`, `ResultManifest::Build`, `ArtifactIngestion::Ingest`) | #3937 | Closed 2026-09-22 | File a focused #3930 child issue for connecting the existing transport components to `Provision`. #3937 documented the transport primitives, but it cannot own this remaining gap. |
| 3 | Live macOS-host acceptance evidence (clean-clone iOS / `viamin/ColorMatching-iOS` / native macOS GUI build, test, launch, capture; host isolation; network enforcement; one Apple worker alongside three paid-agent containers) | #3978 | Closed 2026-09-22 | File a focused #3930 child issue for live-host acceptance evidence. #3978 documented the prior validation scope, but it cannot own this remaining gap. |

## Conclusion

No broad rollout, feature-flag cleanup, or epic closure is justified. The
existing design invariants remain valid; the next implementation work must
wire approved configuration, source transport, guest execution, output
ingestion, and cleanup into one attempt path, then collect the required live
macOS evidence before a final closeout. Before that work can be auto-picked,
new focused child issues must be filed under #3930 for each of the three gaps; issues #3936, #3937, and #3978 are closed historical references, not open owners.
