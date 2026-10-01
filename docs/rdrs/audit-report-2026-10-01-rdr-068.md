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

## Gap reconciliation to existing trackers

Per checklist step 3, each unmet criterion must either have its own focused
tracker or be reconciled to an existing one so Paid's auto-pick cannot
double-assign the same scope. Two of the three gaps below map cleanly to
children of umbrella `#3930` already documented in the 2026-09-22 audit
([`audit-report-2026-09-22-rdr-068.md`](audit-report-2026-09-22-rdr-068.md) §
Gaps and reconciliation to existing trackers). Gap 1 — the per-attempt
protocol dispatch wiring — is not owned by title by any existing child of
`#3930` (`#3936` scheduling, `#3940` MCP/gates, `#3938` closed config/approval,
`#3937` transport), but the 2026-09-22 audit's recorded scope for `#3936`
explicitly includes "the sequential multi-profile execution scheduler that
consumes a parsed config and runs the profiles one after the other"
([`audit-report-2026-09-22-rdr-068.md`](audit-report-2026-09-22-rdr-068.md)
F4 row); the per-attempt dispatch wiring inside `Provision#guest_manifest` is
the per-profile piece of that same scope. So Gap 1 is reconciled to `#3936`
rather than filed as a parallel new tracker — the alternative would create a
second auto-pickable issue for the same component, exactly the failure mode
checklist step 3 warns against. Each row below records the mapping and the
reason the existing tracker already covers it.

| # | Gap | Tracker | Status | Why the existing tracker covers it |
|---|---|---|---|---|
| 1 | Approved workflow dispatch wiring inside `Provision#guest_manifest` (derives the approved configuration's `build` / `test` / `launch_app` / UI-flow / `capture` operations from the approved revision's project/scheme/test-plan declarations and dispatches them through the guest protocol) | #3936 | open | #3936's scope (per the 2026-09-22 audit) explicitly covers "the sequential multi-profile execution scheduler that consumes a parsed config and runs the profiles one after the other" and the F8 follow-on "a parsed build/test-only config drives a real run end-to-end." The per-attempt protocol payload inside `Provision` is the per-profile piece of that same scope; without it, #3936's scheduler has only `materialize_source` and `export_artifacts` to emit. Filing a parallel child issue for the dispatch wiring would create a second auto-pickable tracker against the same component. |
| 2 | Source / result / artifact components not invoked from the dispatch path (`SourceLane::Build`, `ResultManifest::Build`, `ArtifactIngestion::Ingest`) | #3937 | open | #3937's scope (per the 2026-09-22 audit) explicitly covers output manifests with failure class, lineage, provenance, and summaries; `.xcresult`/log/screenshot/diagnostics under Paid artifact retention; and the RDR's revocation/deletion rules for retained failed VMs and expired bundles. The transfer components that gap 2 names are the transport primitives #3937 owns; connecting them to `Provision` is part of #3937's scope. |
| 3 | Live macOS-host acceptance evidence (clean-clone iOS / `viamin/ColorMatching-iOS` / native macOS GUI build, test, launch, capture; host isolation; network enforcement; one Apple worker alongside three paid-agent containers) | #3978 | open | #3978 was filed from the 2026-09-22 audit as the child of #3930 that owns the live-host run, and its acceptance criteria explicitly cover F1/F2/F3 and R5 plus the live S1/S3 evidence. No new evidence has been recorded against it since the 2026-09-22 audit, so gap 3 is the same scope as gap 1 of the prior reconciliation and the existing tracker already owns it. |

## Conclusion

No broad rollout, feature-flag cleanup, or epic closure is justified. The
existing design invariants remain valid; the next implementation work must
wire approved configuration, source transport, guest execution, output
ingestion, and cleanup into one attempt path, then collect the required live
macOS evidence before a final closeout. The three required gaps are
reconciled to existing open children of #3930 (#3936, #3937, #3978) above,
following the checklist step 3 anti-pattern warning against catch-all or
duplicate-scope gap issues.
