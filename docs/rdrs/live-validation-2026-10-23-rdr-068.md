# RDR-068 Live Validation Report

Hand-recorded for issue #4274 (live-host acceptance validation of RDR-068,
successor to the closed #3978). `bin/apple-verify-live` refuses to execute
(`--run` exits before writing a report) once its preflight check fails, so
this report documents that preflight failure directly rather than a harness
render. Evidence statuses are fail-closed per
`docs/rdrs/live-validation-runbook-rdr-068.md`: a criterion is satisfied only
by live, passing scenario runs. None ran. No status below is fabricated, and
that includes AC8 — the `report-archived-under-docs-rdrs` scenario is passed
only by the harness writing its own generated report
(`bin/apple-verify-live:332-343`), which never happened here. This file is the
blocker record for that failure, not the evidence it asks for.

## Run metadata

- attempted: 2026-10-23
- environment: Linux coding-agent sandbox (this repository's automated
  execution environment); no macOS or Apple Silicon host reachable
- control_plane: `main`@`132a9ca` (HEAD at attempt time)
- repeats requested: n/a — `--run` was not reached
- command: `bin/apple-verify-live --plan`

```
RDR-068 live validation scenario matrix (issue #3978)

  functional-smoke-ios-app                     AC1  functional     build_test_launch_capture
  functional-colormatching-ios                 AC2  functional     build_test_launch_capture
  functional-macos-gui-app                     AC3  functional     build_test_launch_capture
  recovery-cancellation                        AC4  recovery       ledger_converged
  recovery-timeout                             AC4  recovery       ledger_converged
  recovery-control-plane-restart               AC4  recovery       ledger_converged
  recovery-host-restart                        AC4  recovery       ledger_converged
  recovery-partial-provisioning                AC4  recovery       ledger_converged
  recovery-orphan-discovery                    AC4  recovery       ledger_converged
  isolation-host-ssh                           AC5  isolation      denied_on_live_host
  isolation-host-filesystem                    AC5  isolation      denied_on_live_host
  isolation-personal-data                      AC5  isolation      denied_on_live_host
  isolation-keychain                           AC5  isolation      denied_on_live_host
  isolation-devices                            AC5  isolation      denied_on_live_host
  isolation-container-runtime                  AC5  isolation      denied_on_live_host
  network-direct-ip                            AC6  network_policy denied_and_audited
  network-alternate-dns                        AC6  network_policy denied_and_audited
  network-proxy-override                       AC6  network_policy denied_and_audited
  network-unsupported-protocol                 AC6  network_policy denied_and_audited
  network-compliant-request                    AC6  network_policy permitted
  capacity-alongside-three-agent-containers    AC7  capacity       within_thresholds
  report-archived-under-docs-rdrs              AC8  reporting      report_written

22 scenarios across 8 acceptance criteria.

Preflight: APPLE_VERIFICATION_HOST_URL is not configured; APPLE_VERIFICATION_HOST_TOKEN is not configured; APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN is not configured; --project is required (Paid project id for the validation run); --image is required (approved Apple verification image digest)
```

Supporting check — no Apple-verification infrastructure exists for this
environment to target even with credentials supplied:

```
$ bin/rails runner 'TenantContext.with_system_access { puts [AppleVerificationImage.count, AppleWorkerProfile.count, AppleVerificationAttempt.count].inspect }'
[0, 0, 0]
```

## Acceptance criteria

| Criterion | Description | Status | Evidence |
|---|---|---|---|
| AC1 | Clean VM clones repeatedly build, test, launch, and capture the smoke iOS app through the shipped control plane. | unmet | 0 scenarios executed |
| AC2 | Clean VM clones repeatedly build, test, launch, and capture viamin/ColorMatching-iOS through the shipped control plane. | unmet | 0 scenarios executed |
| AC3 | A representative native macOS GUI application builds, tests, launches, and produces an app-window screenshot. | unmet | 0 scenarios executed |
| AC4 | Cancellation, timeout, control-plane restart, host restart, partial provisioning, and orphan-discovery scenarios converge to audited ledger states during the live runs. | unmet | 0 scenarios executed |
| AC5 | Adversarial isolation evidence collected on the live host. | unmet | 0 scenarios executed |
| AC6 | Adversarial network-policy evidence collected on the live guest. | unmet | 0 scenarios executed |
| AC7 | One Apple worker operates alongside three active paid-agent containers within capacity thresholds. | unmet | 0 scenarios executed |
| AC8 | The live-validation report is archived under docs/rdrs/ and cross-referenced from the next RDR-068 closeout. | unmet | 0 scenarios executed — `--run` exits at preflight before the runner writes its generated report; this file is the preflight record, not harness evidence |

## Gaps

- **AC1–AC3 (functional).** No macOS/Tart host is configured
  (`APPLE_VERIFICATION_HOST_URL`/`APPLE_VERIFICATION_HOST_TOKEN` unset), no
  `AppleVerificationImage` exists to pass as `--image`, and no guest executor
  is reachable. None of the smoke iOS app, `viamin/ColorMatching-iOS`, or a
  native macOS GUI app scenario could be dispatched.
- **AC4 (recovery).** The automated recovery scenarios run through the same
  `ControlPlaneLifecycle`/host-service port as the functional scenarios and
  share the same blocker; none executed.
- **AC5 (isolation).** No guest-executor diagnostics endpoint exists to
  answer the isolation probes, and no VM was provisioned to observe manually
  (`tart list`, Softnet interface inspection) — there is no Tart installation
  in this environment at all.
- **AC6 (network policy).** The adversarial network probes run against a
  run's resolved guest contract, which requires a provisioned attempt; none
  was provisioned.
- **AC7 (capacity).** The capacity sampler reads the host service's
  readiness payload; no host service is reachable, so no sample could be
  taken alongside the three paid-agent containers.
- **AC8 (reporting).** No harness-generated report exists. The
  `report-archived-under-docs-rdrs` scenario is passed by the runner only
  after it writes that report (`bin/apple-verify-live:332-343`), and
  `--run` exited at preflight (`bin/apple-verify-live:284-290`) before the
  runner was constructed. This hand-recorded preflight record is committed at
  the path a same-day run would have used; it is blocker documentation, not
  evidence, and it is superseded — never patched in place — by the first real
  run's generated report.
- **Owner for all of the above:** #4274 (this issue), which stays open.
  Rerun condition: an operator completes
  `docs/rdrs/apple-worker-operator-guide.md` on real macOS/Apple-Silicon
  hardware (physical or cloud-hosted), publishes an active
  `AppleVerificationImage`, exports the three `APPLE_VERIFICATION_*`
  credentials to the control plane's web/job processes, and re-runs
  `bin/apple-verify-live --run --project <id> --image <digest>
  --guest-diagnostics <url>` per
  [`live-validation-runbook-rdr-068.md`](live-validation-runbook-rdr-068.md).
  No further code change in this repository can substitute for that
  operator action — the dispatch and transport preconditions the runbook
  calls out (#4272, #4273) are already resolved on `main`.

## Enablement recommendation

`apple_verification_workers` stays **default-off** for every project,
including the three pilot projects named in #4274 (the smoke SwiftUI app,
`viamin/ColorMatching-iOS`, and a native macOS GUI application), until a live
run records every AC1–AC8 criterion satisfied and this report is superseded
by one generated by `bin/apple-verify-live --run` itself.

## Archival

This preflight record is committed at
`docs/rdrs/live-validation-2026-10-23-rdr-068.md` and is cross-referenced
from [`audit-report-2026-10-23-rdr-068.md`](audit-report-2026-10-23-rdr-068.md).
It does not archive the harness's own report, so it does not satisfy AC8; the
first live run's generated report is what does, at a different path. Because
this file already occupies the harness's default archive path for 2026-10-23,
a run on that date must pass `--out <path>` (the harness refuses to overwrite
an existing report). See `docs/rdrs/live-validation-runbook-rdr-068.md` for the
full operator procedure.
