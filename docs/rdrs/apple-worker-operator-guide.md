# Apple Worker Operator Guide (RDR-068 / issue #3941)

This guide is the **only** Markdown operator guide for the Apple
verification worker. It is generated from the same plan format
`bin/apple-worker-setup --plan` prints, so the canonical operator actions
and the rendered preflight plan never drift. There is no PDF or
independently maintained duplicate.

Routine project configuration, workflow approval, and verification **do
not require a guest login** — the guest account `paidguest` enters its
isolated GUI session automatically and never accepts a user. The
first-release setup **does not require an Apple ID**: build, test,
Simulator, and screenshot operations are wired against the free Xcode
command-line toolchain and a freshly cloned immutable base image.

## Audience

This document is written for a Paid operator setting up a fresh macOS
worker host for the first time, or repairing an existing host that has
drifted out of compliance. The one-time operator actions below are the
only host-state changes the host must accept; everything else is driven
from the control plane.

## Required reading

- RDR-068 — [Apple Platform Verification Workers](RDR-068-apple-platform-verification-workers.md)
  (§ Operator Setup and Maintenance is the high-level contract this guide
  implements).
- The closed-source `.paid/apple-verification.yml` parser is documented
  in [`docs/intent/apple-verification-workers/`](../intent/apple-verification-workers/apple-verification-workers-design.md).
- The guest protocol and executor boundary are documented in
  [`docs/intent/apple-guest-execution/`](../intent/apple-guest-execution/).

## Roles

| Role | Responsibility |
|---|---|
| Operator | Runs `bin/apple-worker-setup`, completes the manual actions below, publishes the worker profile, monitors quarantine and recovery. |
| Project administrator | Approves a committed workflow digest and waives individual required attempts. The operator is never asked to log into the guest. |
| Paid agent | Iterates on workflow code through the shipped `GuestProtocol` vocabulary; cannot approve workflows or waive attempts. |

## TL;DR — first-time setup

```bash
# 1. Clone the repo on the macOS worker host and install dependencies.
bin/setup --skip-server

# 2. Confirm the control plane can reach the host service and that the
#    host service can reach the egress proxy.
APPLE_VERIFICATION_HOST_URL=https://macos-worker.internal/lifecycle \
APPLE_VERIFICATION_HOST_TOKEN="$(cat /etc/paid/host-token)" \
bin/apple-worker-setup --preflight

# 3. Run the automated smoke scenarios against a published image.
APPLE_VERIFICATION_HOST_URL=https://macos-worker.internal/lifecycle \
APPLE_VERIFICATION_HOST_TOKEN="$(cat /etc/paid/host-token)" \
bin/apple-worker-setup --smoke \
  --project <paid-project-id> \
  --image <active-image-digest>

# 4. Archive the report.
APPLE_VERIFICATION_HOST_URL=https://macos-worker.internal/lifecycle \
APPLE_VERIFICATION_HOST_TOKEN="$(cat /etc/paid/host-token)" \
bin/apple-worker-setup --all \
  --project <paid-project-id> \
  --image <active-image-digest> \
  --report docs/rdrs/apple-worker-setup-<date>.md
```

The `--preflight` step is **read-only** and safe to run any number of
times. `--smoke` provisions a short-lived guest through the production
lifecycle port and tears it down; it is destructive on the worker host
inside the published image, not on the host shell.

## 1. Grant virtualization permission

macOS requires explicit consent before user-mode code can drive
hypervisor frameworks.

1. Open **System Settings → Privacy & Security → Apple Virtualization**.
2. Enable the toggle for the user account that runs the host service
   (`paid-operator` by default; create a dedicated account rather than
   reusing a personal one).
3. Verify on the host:
   ```bash
   sysctl -n kern.hv_vmm_present
   # must print 1
   ```
4. Confirm SIP does not block virtualization in your macOS build:
   ```bash
   csrutil status
   # "System Integrity Protection status: enabled" is fine.
   ```

If `kern.hv_vmm_present` is still `0`, reboot — the toggle does not
take effect until the next login.

## 2. Install Tart and Softnet

Tart is the first macOS virtualization provider RDR-068 ships against.
Softnet is its built-in network namespace that keeps the guest off the
host LAN.

```bash
brew update
brew install cirruslabs/cli/tart
tart --version               # must report major 2 or later
sudo tart softnet start
tart softnet status           # must include "running"
```

Both binaries live under `/opt/homebrew/bin` on Apple Silicon and
`/usr/local/bin` on Intel. The preflight discovers them via
`which tart`; no `PATH` override is required.

## 3. Create and publish the base image

The base image is the immutable macOS guest the host service will
clone. Operator action:

1. Clone the immutable source image (downloaded once from the operator's
   internal mirror):
   ```bash
   tart clone ghcr.io/cirruslabs/macos-ventura-base:latest paid-macos-base
   ```
2. Confirm the local digest matches the expected `sha256:` value:
   ```bash
   shasum -a 256 paid-macos-base
   # Compare against the value in the worker profile definition.
   ```
3. Publish the `AppleVerificationImage` row in the admin UI (or via
   `bin/rails runner 'AppleVerificationImage.create!(...)'`), filling
   in:
   - `digest` — the `sha256:<hex>` reported above;
   - `toolchain` — `macos_version`, `macos_build`, `xcode_version`,
     `xcode_build`, `sdk_versions`, `simulator_runtimes`,
     `executor_version`;
   - `resources` — `cpu_count`, `memory_gib`, `disk_gib`;
   - `network_capability` — `mechanism: "softnet"`,
     `egress_enforced: true`;
   - `gui_account` — see §4;
   - `smoke_test` — `{ "passed": true, "ran_at": "<iso8601>" }` after
     the smoke test below passes;
   - `provenance.guest_executor_url` — the credential-free HTTPS
     endpoint the deterministic guest executor answers on.
4. Promote the image to `active` only after the smoke test passes; the
   `AppleVerificationImage` model rejects promotion without a passing
   smoke test.

## 4. Install Xcode and Simulator runtimes

The first release does **not** require an Apple ID. Build, test,
Simulator boot, and screenshot capture all work with the free Xcode
command-line toolchain plus a runtime downloaded through Xcode's
platform manager.

```bash
# Install the Xcode command-line tools (or full Xcode.app from the
# App Store if your team already maintains it).
xcode-select --install
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# Accept the license exactly once.
sudo xcodebuild -license accept

# Confirm Xcode and the iOS Simulator runtime.
xcodebuild -version           # must print "Xcode <version> <build>"
xcrun simctl list runtimes    # must list iOS / iPadOS / macOS runtimes

# If a runtime is missing, download it via Xcode itself.
xcodebuild -downloadPlatform iOS
```

RDR-068 limits the supported bootstrap systems to Swift Package Manager;
do not introduce CocoaPods, Carthage, Bazel, or Tuist as part of
release-one setup. Future RDRs cover each of those deterministic
adapters.

## 5. Create the guest GUI account

The deterministic guest executor signs in to a dedicated non-admin
account that enters an isolated GUI session automatically. No Apple ID,
no iCloud linkage, no admin group, no host credentials, no persistent
secret-bearing keychain.

```bash
# Create the dedicated account.
sudo sysadminctl -addUser paidguest \
  -fullName 'Paid Verification' \
  -UID 555 -GID 20 \
  -shell /bin/zsh

# Confirm the account has no admin privileges.
dseditgroup -o checkmember -m paidguest admin
# must print "no" or "not a member"

# Disable screen locking for the dedicated account's GUI session so
# unattended runs do not stall.
sudo defaults write /Library/Preferences/com.apple.loginwindow \
  DisableScreenLockOverride -bool YES

# Disable the screen saver password prompt for the same account.
sudo -u paidguest defaults write com.apple.screensaver askForPassword -int 0
```

The login window must auto-launch into `paidguest`; on Apple Silicon,
configure `AutoLoginUser` under
`/Library/Preferences/com.apple.loginwindow.plist` and pair it with the
`/etc/kcpassword` placeholder (write-protect 0600). The setup harness
records this expectation so the smoke test can probe it through the
guest executor diagnostics endpoint.

## 6. Register the host service

The trusted host service is the **only** Paid-controlled process that
runs on the macOS worker host. Its API surface is the
`AppleVerification::HostService` fixed vocabulary (`readiness`, `clone`,
`start`, `inspect`, `stop`, `destroy`, `inventory`) and it deliberately
cannot express commands, paths, or mounts.

1. Drop the launchd plist under `/Library/LaunchDaemons/`:
   ```bash
   sudo cp config/com.paid.macos-host.plist /Library/LaunchDaemons/
   sudo launchctl load /Library/LaunchDaemons/com.paid.macos-host.plist
   ```
2. Mint a bearer token and store it at `/etc/paid/host-token` (mode
   `0600`, owner `root`):
   ```bash
   sudo mkdir -p /etc/paid
   sudo install -m 0600 /dev/null /etc/paid/host-token
   bin/paid host-service rotate-token | sudo tee /etc/paid/host-token
   ```
3. Export `APPLE_VERIFICATION_HOST_URL` and
   `APPLE_VERIFICATION_HOST_TOKEN` on **every** web and job process
   that talks to the host service (the same set that exports
   `DATABASE_URL`):
   ```bash
   export APPLE_VERIFICATION_HOST_URL=https://macos-worker.internal/lifecycle
   export APPLE_VERIFICATION_HOST_TOKEN="$(cat /etc/paid/host-token)"
   export APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN="$(cat /etc/paid/guest-token)"
   ```
4. Confirm the host service is reachable from the control plane:
   ```bash
   bin/apple-worker-setup --preflight
   ```

## 7. Configure proxy enforcement

The guest network path runs only through the Paid-controlled egress
proxy. Tart's network namespace is wired to the proxy identifier
(`paid-egress`) declared in the `AppleVerification::HostService`
readiness payload; the host service refuses to provision a VM with any
other network profile.

```bash
bin/paid host-service set network.proxy-relay paid-egress
bin/apple-worker-setup --preflight  # confirm "proxy relay=paid-egress"
```

`docs/intent/apple-verification-network-policy/` describes the policy
contract; the smoke test proves the boundary live through the
`network-direct-ip`, `network-alternate-dns`, `network-proxy-override`,
and `network-unsupported-protocol` probes.

## 8. Publish the immutable worker profile

The worker profile binds the project's Xcode and Simulator constraints
to a published image. Profiles are immutable; a constraint change
requires a new profile, not a mutation of the existing one.

```ruby
# bin/rails runner (system-access context)
AppleWorkerProfile.create!(
  account: Account.find_by!(slug: "<account-slug>"),
  name: "ios-standard-26",
  image_digest: "sha256:<hex>",
  capabilities: { "platforms" => %w[ios ipados macos] },
  constraints: {
    "platforms" => %w[ios ipados macos],
    "xcode_version" => ">= 26.0, < 27.0",
    "simulator_runtimes" => [ "iOS 26.0", "iPadOS 26.0" ]
  }
)
```

Approval of a workflow revision requires an active profile whose
constraints match every declared `worker.xcode` and `worker.simulator`
constraint. RDR-068's `AppleVerificationWorkers::VersionRequirement`
parser rejects mismatches at sync time before any worker is provisioned.

## 9. Run the automated smoke tests

The smoke suite proves the four acceptance criteria the operator needs
to see before enabling the feature for a pilot project:

```bash
bin/apple-worker-setup --smoke \
  --project <paid-project-id> \
  --image <active-image-digest> \
  --profile ios-standard \
  --guest-diagnostics https://<guest-executor-host>/diagnostics
```

Scenarios, in order:

| Scenario | Acceptance criterion | Pass criteria |
|---|---|---|
| `permitted-dependency-access` | Guest can reach permitted dependency hosts. | Lifecycle provisions the guest; the SwiftPM `package resolve` manifest returns `outcome: succeeded`; no `EgressSecurityEvent` rows. |
| `host-isolation-probes` | Guest cannot reach host SSH, filesystem, personal data, keychain, devices, or container runtime. | Every diagnostics probe returns `status: denied`. Without a diagnostics endpoint the scenario records a gap, never a pass. |
| `build-test-colormatching-ios` | `viamin/ColorMatching-iOS` builds and tests through the closed `GuestProtocol` vocabulary. | Output manifest reports `build_outcome: succeeded` and `test_outcome: succeeded`. |
| `smoke-ios-app-launch` | Smoke iOS app installs, launches, and reports `launch_outcome: succeeded`. | First screenshot artifact is stored in the artifact lane. |
| `macos-app-screenshot` | Representative native macOS GUI app produces an app-window screenshot. | The captured PNG bytes are non-empty. |

Anything the live host cannot execute records a **gap**, never a pass;
the smoke test is the only path to a passing isolation or dependency
evidence row.

## 10. Routine operation

After first-time setup, routine project use and workflow approval
require no guest login. The control plane drives the lifecycle, the
guest executor handles every guest-side operation through the closed
`GuestProtocol` vocabulary, and Paid-agents iterate via the
control-plane MCP tools (covered by issue #3940).

Operator responsibilities are limited to:

- **Profile updates** — publish a new `AppleWorkerProfile` whenever the
  toolchain changes (new Xcode major, new Simulator runtime). Deprecate
  the old profile after the migration window. The setup command's
  preflight reports the active profile and warns when the published
  image no longer matches.
- **Deprecation / revocation** — run `bin/paid apple-worker profile
  deprecate <id> --reason "<reason>" --retirement <iso8601>` to mark a
  profile deprecated. New approvals are blocked once deprecated;
  `retire` finalizes it once the retirement time arrives; `revoke`
  immediately deactivates the profile and quarantines every host that
  has provisioned it within the last hour.
- **Quarantine and return-to-service** — the worker host quarantines
  itself after repeated health failures. To return it to service:
  ```bash
  bin/apple-worker-setup --smoke \
    --project <paid-project-id> --image <active-image-digest> \
    --guest-diagnostics https://<guest-executor-host>/diagnostics
  bin/paid apple-worker profile return-to-service <id>
  ```
  The quarantine is lifted only after the isolation smoke scenario
  passes.
- **Recovery** — after a host restart, control-plane restart,
  cancellation, or timeout, `bin/apple-worker-setup --preflight` reports
  the current capacity and the host service's per-tag inventory; the
  shipped reconciler converges orphaned VMs through the host service
  `destroy` call.
- **Cleanup** — `bin/paid apple-worker reconcile --destroy-orphans`
  destroys every VM that is no longer bound to an in-flight run; the
  retention sweep deletes the source bundle and quarantine record once
  their retention windows elapse.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Preflight reports a `gap` on `virtualization_permission`. | The toggle has not been enabled for the host-service account, or the host has not been rebooted. | Re-enable the toggle, reboot, re-run `--preflight`. |
| Preflight reports a `gap` on `tart_binary`. | Tart is older than major 2, or not on `PATH`. | `brew upgrade cirruslabs/cli/tart`, confirm with `tart --version`. |
| Preflight reports a `gap` on `softnet`. | `sudo tart softnet start` has not been run, or the daemon was unloaded at boot. | Run `sudo tart softnet start`, confirm with `tart softnet status`. |
| Preflight reports a `gap` on `approved_image`. | The local `paid-macos-base` digest does not match the published `AppleVerificationImage#digest`. | Re-clone or republish; both must report the same `sha256:<hex>`. |
| Preflight reports a `gap` on `xcode_toolchain`. | Xcode license not accepted, or `xcode-select` points at a non-developer directory. | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept`. |
| Preflight reports a `gap` on `simulator_runtimes`. | The iOS Simulator runtime has not been downloaded for the current Xcode. | `xcodebuild -downloadPlatform iOS`; repeat for every runtime the worker profile declares. |
| Preflight reports a `gap` on `guest_gui_account`. | The `paidguest` account is missing, has admin group membership, or is iCloud-linked. | Re-create the account via `sysadminctl -addUser` (no Apple ID, no admin group), re-run `--preflight`. |
| Preflight reports a `gap` on `host_service_authentication`. | `APPLE_VERIFICATION_HOST_TOKEN` is unset or stale, or the host service is not running. | Restart launchd (`sudo launchctl kickstart -k system/com.paid.macos-host`), rotate the token, re-export the env var on every web and job process, re-run `--preflight`. |
| Preflight reports a `gap` on `proxy_enforcement`. | `network.proxy_relay` is not `paid-egress` in the host service readiness payload. | Run `bin/paid host-service set network.proxy-relay paid-egress`, re-run `--preflight`. |
| Preflight reports a `gap` on `capacity`. | Free host disk is below the operator minimum, free memory is below 25%, or more than one Apple VM is active. | Free disk (`df -g /`); reconcile orphan VMs (`bin/paid apple-worker reconcile --destroy-orphans`); re-run `--preflight`. |
| Smoke `host-isolation-probes` records a `gap`. | The guest executor diagnostics endpoint was not configured (the harness never shells into the guest). | Pass `--guest-diagnostics https://<guest-executor-host>/diagnostics` so the harness can record live evidence. |
| Smoke `build-test-colormatching-ios` records a `gap`. | The executor has not been wired into the guest image yet (covered by issue #3937). | Re-run `--smoke` once the executor ships; until then the scenario records a gap, never a pass. |
| Smoke `permitted-dependency-access` records a `gap`. | The image digest does not match an active, schedulable image in the account. | Confirm `--image` matches `AppleVerificationImage.active.first.digest`. |

## Appendix A — Host service readiness payload

```json
{
  "cpu":        { "available_cores": 10, "model": "Apple M1 Pro" },
  "memory":     { "free_percent": 47, "pressure": "nominal" },
  "disk":       { "free_gib": 312 },
  "images":     [ "paid-macos-base sha256:abc..." ],
  "network":    { "proxy_relay": "paid-egress", "softnet": "running" },
  "guest_connection": { "url": "https://<guest-executor-host>/diagnostics" }
}
```

The proxy relay value is what the setup preflight validates; the
`guest_connection.url` is what the smoke test uses to record live
isolation evidence.

## Appendix B — Release-one exclusion list

RDR-068 release-one **deliberately** excludes:

- TestFlight, App Store Connect, distribution signing, notarization,
  packaging, Mac App Store, App Store submission.
- Physical-device testing and any workflow requiring host devices or
  personal data.
- System extensions, privileged helpers, kernel extensions, installers,
  MDM entitlements.
- Arbitrary project bootstrap commands. Swift Package Manager is the
  only supported bootstrap system until each CocoaPods, Carthage,
  Bazel, and Tuist adapter ships in a follow-up RDR.
- Shared mutable dependency or build caches between projects.
- Coding-agent or LLM execution inside the guest.

If a project needs any of those, file a follow-up RDR; the operator
setup must not be used to bypass the boundary.

## Appendix C — Cross-references

- RDR-068 — [Apple Platform Verification Workers](RDR-068-apple-platform-verification-workers.md)
- `docs/intent/apple-worker-setup/` — design + EARS specs for this guide
- `docs/rdrs/live-validation-runbook-rdr-068.md` — live-host acceptance
  evidence (issue #3978)
- `docs/rdrs/audit-report-2026-09-22-rdr-068.md` — RDR-068 closeout
  audit and gap reconciliation
