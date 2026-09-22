---
parent: PAID
prefix: APPLE-SETUP
---

# Low-Level Design: Apple Worker Operator Setup

Apple worker setup is a one-time operator responsibility that produces a
reproducible macOS guest the control plane can invoke without any further
operator action. The setup pipeline is read-only until the operator explicitly
asks for changes: it inspects the host, validates the immutable guest image,
checks the host-service authentication, and runs the isolation and
dependency-access smoke tests that the RDR-068 acceptance criteria demand.
The output is a structured report with the exact manual operator actions the
host needs (grant virtualization permission, install Tart and Softnet, accept
the Xcode license, install Simulator runtimes, create the guest account, and
publish the worker profile). The setup command itself never falls back to
running project code on the host; the isolation smoke test invokes only the
shipped trusted host boundary, the approved guest executor, and the closed
guest protocol — exactly the surfaces Paid itself uses.

## Read-only preflight

The preflight runs in a single shell-out per check and is fail-closed: every
check has an explicit pass, warn, or gap status with the precise command the
operator should run when the check fails. Preflight covers:

| Check | Source | Failure action |
|---|---|---|
| macOS virtualization permission | `sysctl kern.hv_vmm_present` returns 1 and a benign `csrutil` status | Prompt the operator to enable Apple virtualization in System Settings → Privacy & Security and confirm `sysctl kern.hv_vmm_present=1`. |
| Tart binary | `tart --version` exits 0 and reports a compatible major | Document the `brew install cirruslabs/cli/tart` step and the minimum supported major. |
| Softnet | `tart softnet status` reports `running` or the operator runs `tart softnet start` once | Reference the RDR-068 isolation contract. |
| Approved image identity | `tart list` includes the image whose `sha256:` digest matches the `AppleWorkerProfile#image_digest` constraint bound to the account | Either clone the immutable image via `tart clone <source>` or publish a fresh `AppleVerificationImage` row through the admin UI; the report prints the missing digest so the operator can reconcile. |
| Xcode toolchain | `xcode-select -p` resolves, `xcodebuild -version` reports a build, and the license is accepted | Document `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` and `sudo xcodebuild -license accept`. |
| Simulator runtime | `xcrun simctl list runtimes` includes the profile's declared runtimes | Document `xcodebuild -downloadAllPlatforms` and `xcodebuild -downloadPlatform iOS`; surface the missing runtime names. |
| Guest GUI readiness | The dedicated guest account exists, is non-admin, has no Apple ID, and `launchctl print-disabled gui/<uid>` reports screen locking disabled for unattended GUI sessions | Reference `sysadminctl -addUser` (no Apple ID), `dseditgroup -o edit -a <account> -t user _developer`, and `defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLockOverride -bool YES` only for the dedicated guest session. |
| Host service authentication | The control-plane `APPLE_VERIFICATION_HOST_URL` and `APPLE_VERIFICATION_HOST_TOKEN` reach the host service; `readiness` returns `200 OK` with the readiness payload | Document the launchd registration and the bearer token rotation procedure. |
| Proxy enforcement | The host-service readiness payload declares `proxy-relay="paid-egress"` and the network profile wired by `TartProvider` resolves to the same identifier | Reference the RDR-068 network-policy contract. |
| Capacity | Free disk ≥ the operator-configured minimum (default 60 GiB), free memory ≥ 25%, active Apple VM count ≤ 1, and projected guest disk ≥ 15 GiB after clone | Reference the operator-configurable thresholds; report the measured values so the operator knows the safe margin. |

Preflight never invokes the guest executor, never runs project code, and
never modifies host state. It returns a `Preflight::Report` whose checks and
fix-it actions drive the operator-facing Markdown guide.

## Smoke tests

The smoke tests exercise only the shipped control-plane boundaries against
the host's actual installed artifacts. Every test is fail-closed and
records a structured result the operator can paste into the issue thread:

1. **Permitted dependency access.** Provision a clean `ios-standard` clone
   of the published image through the shipped `AppleVerification::Lifecycle`
   port, hand the guest a manifest that asks for a SwiftPM `swift package
   resolve` against `github.com/pointfreeco/swift-snapshot-testing` (a
   well-known allowed host), and assert the guest executor returns a
   resolved package graph with an `outcome: succeeded` response and zero
   `EgressSecurityEvent` rows. The same guest cannot reach a denied
   destination (the report asserts `EgressSecurityEvent` for the denied
   probe). Without `allowed_host` the scenario records a gap, never a pass.
2. **Host isolation.** With the same VM running, the executor's diagnostics
   endpoint reports `denied` for `isolation-host-ssh`,
   `isolation-host-filesystem`, `isolation-personal-data`,
   `isolation-keychain`, `isolation-devices`, and
   `isolation-container-runtime`. The setup script records each probe's
   status without ever shelling into the guest. Without the diagnostics
   endpoint configured, the scenario records a gap naming the missing
   provider, never a pass or a fail.
3. **Build / test execution.** Dispatch a `build` + `test` operation
   against the `viamin/ColorMatching-iOS` reference scheme through the
   closed `GuestProtocol` vocabulary; assert the parsed output manifest
   carries `build_outcome: succeeded`, `test_outcome: succeeded`, and a
   non-empty `.xcresult` reference. This is the only scenario that runs
   Xcode; the smoke VM is short-lived and destroyed immediately.
4. **App launch.** Dispatch `install_app` + `launch_app` for the smoke
   `HelloWorld.app`, poll the readiness condition, then `capture` the
   simulator screen. Assert the captured artifact bytes are non-empty and
   the manifest declares `launch_outcome: succeeded`.
5. **Screenshot export.** For a representative native macOS GUI project
   (advisory + smoke-only), dispatch `launch_app` against a `macos` target,
   wait for the window, and capture the app window. Assert the captured
   PNG bytes are non-empty.

Every smoke scenario provisions through the same lifecycle port and runs
through the same admission boundary the production scheduler will use, so a
passing smoke run is concrete proof that an Apple worker can satisfy the
RDR-068 acceptance criteria without ever touching the host shell.

## Plan and report

`AppleVerification::Setup::Plan` translates the preflight and smoke
results into a numbered manual action plan. Each action carries:

- the check that surfaced it;
- the exact shell command(s) the operator should run;
- the expected output that proves success; and
- the link in the README the operator should read first.

`AppleVerification::Setup::Report` renders the preflight checks, smoke
results, and operator plan as Markdown. The canonical Markdown operator guide
at `docs/rdrs/apple-worker-operator-guide.md` consumes that same plan
format so there is one source of truth and no independently maintained
duplicate guide.

## Driver

`bin/apple-worker-setup` is the operator entry point. It defaults to
read-only preflight (`--preflight`); `--plan` renders the action plan;
`--smoke` runs the five smoke scenarios against the configured host;
`--report PATH` writes a Markdown report. The driver never modifies host
state, never writes to the database (it reads `AppleVerificationImage` rows
under `TenantContext.with_system_access`), and never shells into the guest.
Its exit code is non-zero if any preflight check is in the `gap` state or
any smoke scenario fails; warnings are surfaced as warnings, not as
failures.

*HLD:* `docs/high-level-design.md` → Apple verification workers.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
