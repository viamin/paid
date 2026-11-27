# Temporal worker stall acceptance — 2026-11-27

## Environment and source

The Paid devcontainer is the available operating environment. No production
system is deployed. Evidence below was collected on Linux arm64 with Ruby
3.4.13; the native bridge was built with Rust 1.100.1 and protoc 34.0.

- Paid base: `3497e0f4bc5d929ea05123cb1d4860ca02cf78bc`.
- Candidate branch: `fix/temporal-worker-stall`.
- SDK source: `a49ec2218474991a94ee2bb3cd47194d2bbf98b1`
  in `viamin/sdk-ruby`, based on SDK 1.12.0.
- Core source: `0bf830696a9952bd56629983b8dda373503d4bc3`.
- Compiled bridge SHA-256:
  `c8e6a9e8b9180d5bf0864bc3f1eaba80e88ef22b236cc655b22486e9fc516c0b`.

The live checkout also contains the unmerged
[PR #5603](https://github.com/viamin/paid/pull/5603) overlay and additional
GoodJob shutdown edits. Those changes were preserved. A clean-main baseline
was not run. The isolated SDK reproduction does not load Rails or that overlay.

## Failure evidence

Thirteen runs created in the preceding 24 hours had been marked `timeout` by
the stale-run detector; eight had no `started_at`. This includes provisioning
failures, so these rows do not establish thirteen agent execution overruns.

The first poll worker stopped publishing readiness heartbeats at 19:03 UTC.
The poll queue subsequently held approximately 820 workflow tasks and 124
activities. Run 32076 provisioned its container but its `CheckProxyHealth`
activity never started before the 600-second schedule-to-start timeout.
Failure publication and cleanup coordination on the same queue also stalled.

Native backtraces established a lock cycle: a Ruby activity heartbeat retained
the GVL while waiting for Core's outstanding-activity mutex; Core held that
mutex while waiting for a Ruby custom-slot notification. The SDK reactor and
other Ruby threads could not acquire the GVL. Released SDK 1.12.0 reproduced
this failure in a bounded subprocess, which exceeded its 120-second deadline.

The agent worker separately looped inside GC marking. Read-only traversal of
Ruby's global GC-root list encountered an existing node again after eleven
steps. SDK 1.9.0's custom-slot permits use the foreign-thread cleanup mechanism
corrected by [sdk-ruby#569](https://github.com/temporalio/sdk-ruby/pull/569).
That known defect matches the observed GC corruption and earlier native crash.

The existing JSON 3 constraint excludes the newer SDK's supported JSON 2
requirement. Adoption therefore changes both the SDK and JSON resolution.

## Correction and checks

The source pin includes the deferred GC cleanup and the heartbeat bridge
correction proposed in [sdk-ruby#699](https://github.com/temporalio/sdk-ruby/pull/699).
A second source-only loader correction supports RubyGems' flat Cargo-extension
installation path. Paid explicitly retains fixed pollers, provisions source
build prerequisites, and activates Bundler before worker readiness helpers.
An unbundled entrypoint test failed on the early JSON activation and passed
when the boot order was corrected.

The corrected native lifecycle subprocess completed 32 workflows with remote
and local activities, GC and heartbeat contention, workflow cancellation, and
exclusive admission-lock recovery. The SDK's new regression passed in both
thread and fiber modes: two runs and 32 assertions. All eight custom-slot tests
passed on an unchanged repeat, with 82 assertions. An initial run hit the
existing simple test's reservation/release count assertion (19 versus 18);
the corresponding released-SDK test also passed when checked separately.

Paid's focused suite passed 68 examples with frozen Bundler resolution,
covering admission, the native lifecycle, payload conversion, saved workflow
replay, setup, observability, and unbundled boot. The run used seed 27696
and completed in 17.56 seconds after loading files.

## Live recovery

Restarting the original workers restored agent execution temporarily. The poll
worker later stalled in the same native heartbeat call. Replacing that process
also stopped the development supervisor's other processes, requiring a full
stack restart. The first patched launch exposed the JSON boot-order conflict;
the corrected entrypoint then started successfully.

At 22:17 UTC, poll PID 584769 and agent PID 584770 both published fresh
heartbeats. Their process maps identified the corrected bridge in the durable,
ignored SDK checkout under `.worktrees/temporal-sdk-heartbeat-source/`.
Fifteen projects had refreshed `last_polled_at` within five minutes, `/up`
returned HTTP 200, and run 32081 completed at 22:11:25 UTC with PR 5527.
The workers' boot observation names Paid base `3497e0f4...` and development
digest `691dbe2a8ec827fa9ff252e8cdb1f45b5c3e9773f25427a71913bcb78b516383`.
Subsequent lockfile normalization changes packaging metadata, not the loaded
SDK source or bridge artifact; it does not establish a new worker boot identity.

## Limits

The full Paid and SDK suites, Rust Clippy, cold Git-gem installation, Docker
image builds, and other architectures were not verified locally. Native
lifecycle acceptance covers the SDK boundary, not arbitrary agent task quality.
The source pin remains temporary pending an upstream release containing the
heartbeat correction. Replace it with a released native gem and remove the
source-build bootstrap when that release is adopted.
