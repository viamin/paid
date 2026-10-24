# RDR-068 Live Validation Preflight Record — 2026-10-24

**Issue:** #4274  
**Status:** blocked; no live scenarios executed  
**Owner:** #4274 (operator provisioning of the macOS/Tart worker host)

This is a fail-closed preflight record, not a generated acceptance report.
The acceptance runner writes a report only after `--run` passes preflight and
executes live scenarios. No macOS worker, guest executor, project, or active
Apple verification image is available to this Linux workspace, so no criterion
or artifact below is claimed as passing.

## Recorded command

```text
$ bin/apple-verify-live --plan
...
22 scenarios across 8 acceptance criteria.
...
Preflight: APPLE_VERIFICATION_HOST_URL is not configured; APPLE_VERIFICATION_HOST_TOKEN is not configured; APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN is not configured; --project is required (Paid project id for the validation run); --image is required (approved Apple verification image digest)
```

The plan now intentionally runs without Rails boot, which makes the host and
request configuration gaps observable even though the supplied `DATABASE_URL`
uses a role the application's runtime-role guard rejects (`SUPERUSER` and
`BYPASSRLS`). That guard remains in force for `--run`; no database-backed
project, image, profile, or attempt inspection was performed with that unsafe
role.

## Acceptance status

| Criterion | Status | Recorded reason |
| --- | --- | --- |
| AC1 | unmet | No live clean-clone smoke SwiftUI build/test/launch/Simulator-capture run. |
| AC2 | unmet | No live `viamin/ColorMatching-iOS` build/test/launch/Simulator-capture run. |
| AC3 | unmet | No live native macOS GUI build/test/launch/app-window capture run. |
| AC4 | unmet | No live lifecycle/recovery scenario could be dispatched. |
| AC5 | unmet | No provisioned guest or diagnostics endpoint produced host-isolation evidence. |
| AC6 | unmet | No provisioned guest contract produced audited network denials or a permitted control request. |
| AC7 | unmet | No host readiness sample measured one VM with three active paid-agent containers. |
| AC8 | unmet | `--run` did not execute or write a generated report under `docs/rdrs/`. This preflight record is not AC8 evidence. |

No protected iOS Simulator or macOS app-window screenshots exist from this
attempt, so none are linked as artifacts.

## Required operator action

On real Apple-Silicon macOS hardware, complete
[the worker operator guide](apple-worker-operator-guide.md): install Tart and
Softnet; publish an immutable Xcode/Simulator image with the dedicated
non-admin guest GUI account; register the authenticated host service and
Paid-controlled proxy; and export the three `APPLE_VERIFICATION_*` values to
the control plane using an application database role that passes the runtime
role guard. Then enable the default-off flag only for the validation project
and run:

```text
bin/apple-verify-live --run --project <id> --image <active-image-digest> \
  --profile ios-standard --repeats 3 --guest-diagnostics <url>
```

The generated report must record passing live evidence for AC1–AC8, including
protected links to both requested screenshot artifacts, before the pilot
projects can be enabled. Until then, `apple_verification_workers` remains
default-off for the smoke SwiftUI app, `viamin/ColorMatching-iOS`, and the
native macOS GUI pilot.
