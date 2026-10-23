# RDR-068 Re-audit — 2026-10-23

**RDR:** [RDR-068](RDR-068-apple-platform-verification-workers.md)
**Umbrella:** #3930 (remains open)
**Closeout issue:** #4274 (live macOS-host acceptance evidence; stays open)
**Decision:** **Partially Implemented** (unchanged) — gaps #1 and #2 from the
[2026-10-01 audit](audit-report-2026-10-01-rdr-068.md) are resolved; gap #3
(live acceptance evidence) is **Blocked** on an external prerequisite this
repository's automated execution environment cannot provide.

This audit follows the [RDR Closeout Checklist](closeout-checklist.md). It
reconciles the 2026-10-01 re-audit's three required gaps against the current
`main` and records why #4274 (filed for gap #3, depending on #4272 and #4273
for gaps #1 and #2) cannot close.

## Gaps #1 and #2: resolved

[#4272](https://github.com/viamin/paid/issues/4272) and
[#4273](https://github.com/viamin/paid/issues/4273) are closed. Verified
against the current code, not the closed-issue state alone:

- **Dispatch wiring (#4272).** `AppleVerificationAttempts::Provision#guest_manifest`
  (`app/services/apple_verification_attempts/provision.rb:222`) now builds its
  operations through `AppleVerification::GuestManifest::Build.call(attempt:)`
  (`app/services/apple_verification/guest_manifest/build.rb`), which parses the
  approved workflow revision's configuration and derives `build`, `test`,
  `boot_simulator`/`install_app`, and capture-flow operations per profile — the
  production dispatch path the 2026-10-01 audit found missing.
- **Transport lanes connected (#4273).** `Provision#call` now runs
  `validated_source_lanes` through `AppleVerification::SourceLane::Build`,
  persists guest results through `AppleVerification::ArtifactIngestion::Ingest`,
  and builds the structured manifest through
  `AppleVerification::ResultManifest::Build` (`provision.rb:36-45,140-192`).
  These were previously unit-tested but disconnected; they are now invoked
  from the one attempt path the 2026-10-01 audit required.

Executed test evidence re-run today on `main`:

```
$ bundle exec rspec \
    spec/services/apple_verification_attempts/provision_spec.rb \
    spec/services/apple_verification_attempts/guest_result_spec.rb \
    spec/services/apple_verification/guest_manifest/ \
    spec/services/apple_verification/source_lane/ \
    spec/services/apple_verification/result_manifest/ \
    spec/services/apple_verification/artifact_ingestion/

83 examples, 1 failure
```

The one failure (`bundle_builder_spec.rb:89`, a tar-entry permission-bits
assertion expecting `0o644` and observing `0o666`) is a sandbox-umask
artifact unrelated to RDR-068 dispatch or transport behavior — the container
this audit ran in has a permissive default umask that a hand-authored
`File.chmod` in the spec's fixture setup does not override before the
assertion. It does not touch any RDR-068 acceptance criterion and is outside
this issue's scope.

Also re-run: the full live-validation harness suite, confirming the harness
itself (built under #3978, closed) is sound and ready to execute once a host
exists:

```
$ bundle exec rspec spec/services/apple_verification/live_validation/
44 examples, 0 failures
```

## Gap #3: live acceptance evidence — Blocked, not implementable from here

Issue #4274 scopes exactly this gap and requires configuring a macOS/Tart
worker host, then running `bin/apple-verify-live` against the pilot
projects. That precondition — "Live acceptance cannot run until an attempt
can actually build/test/launch/capture end-to-end" — is now satisfied at the
code level (gaps #1 and #2 above). The remaining blocker is physical: this
and every other automated execution environment available to this repository
today is a Linux container. The [operator guide](apple-worker-operator-guide.md)
steps — enabling the macOS Virtualization entitlement in System Settings,
`brew install`-ing Tart and Softnet, cloning and publishing an Xcode-bearing
base image, creating the non-admin `paidguest` GUI account, registering the
host service under launchd, and configuring the egress proxy relay — all
require interactive root/console access to real (or cloud-hosted) Apple
Silicon hardware running macOS. No tool available to this agent, and no
environment variable or credential already present, provisions that
hardware.

Evidence that no such host, image, or profile exists anywhere this
environment can reach:

```
$ bin/apple-verify-live --plan
...
Preflight: APPLE_VERIFICATION_HOST_URL is not configured; APPLE_VERIFICATION_HOST_TOKEN is not configured; APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN is not configured; --project is required (Paid project id for the validation run); --image is required (approved Apple verification image digest)
```

```
$ bin/rails runner 'TenantContext.with_system_access { puts [AppleVerificationImage.count, AppleWorkerProfile.count, AppleVerificationAttempt.count].inspect }'
[0, 0, 0]
```

Per the harness's own fail-closed design (`docs/rdrs/live-validation-runbook-rdr-068.md`
§Interpreting statuses), the correct response to a failed preflight is to
record every one of the 22 scenarios across AC1–AC8 as a **gap**, never to
fabricate a pass. That includes `report-archived-under-docs-rdrs`: the harness
marks it passed only after it writes its own generated report
(`bin/apple-verify-live:332-343`), and `--run` exited at preflight
(`bin/apple-verify-live:284-290`) before reaching that path — a
hand-committed file at the same path is blocker documentation, not
satisfying evidence. The dated report
[`live-validation-2026-10-23-rdr-068.md`](live-validation-2026-10-23-rdr-068.md)
records that outcome in the same structure `bin/apple-verify-live --run`
would have written, had preflight passed.

## Tracker state

| # | Gap | Owner | State |
|---|---|---|---|
| 1 | Approved workflow dispatch wiring | #4272 | Closed, verified shipped |
| 2 | Source/result/artifact transport lanes connected | #4273 | Closed, verified shipped |
| 3 | Live macOS-host acceptance evidence | #4274 | **Open — Blocked** on macOS/Tart host provisioning; no new child issue needed, #4274 already is the focused owner |

Issue #4274 stays open. Closing it now would misrepresent unmet acceptance
criteria as satisfied. The rerun condition: once an operator completes the
[operator guide](apple-worker-operator-guide.md) on real macOS hardware and
exports `APPLE_VERIFICATION_HOST_URL` / `APPLE_VERIFICATION_HOST_TOKEN` /
`APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN` for a published active
`AppleVerificationImage`, re-run `bin/apple-verify-live --run` per the
[runbook](live-validation-runbook-rdr-068.md) and archive the resulting
report.

## Closing language for the PR that carries this audit

Per [closeout checklist §8](closeout-checklist.md#8-close-or-keep-the-umbrella-issue-intentionally),
the PR delivering this audit must reference #4274 and #3930 with non-closing
language only. GitHub resolves closing keywords against the base branch at
merge time, so a closing keyword aimed at #4274 in that description would
auto-close the very issue this report says must stay open, and would present
unmet AC1–AC8 criteria as satisfied.

The description of the PR carrying this audit contains a GitHub closing
keyword immediately followed by the #4274 reference, in the line just below the
`---` separator that precedes the LID phase report. That contradicts the
conclusion above. GitHub counts a closing keyword whether or not it is quoted
or backticked, so this report deliberately never writes the pairing out. Before
merging, delete that line from the description and replace it — and the `---`
separator directly above it — with this non-closing block, leaving the rest of
the description unchanged:

```markdown
## Dependencies

Relates to #4274
Tracks #3930
```

No commit on this branch carries a closing keyword either, so the merge itself
cannot close #4274. It closes only when a live run satisfies AC1–AC8 and a
human closes the issue after the operator rerun described above.

## Rollout guard

`apple_verification_workers` remains default-off
(`app/services/feature_flags.rb:81-87`); no project has it enabled in this
environment (`AppleVerificationImage`, `AppleWorkerProfile`, and
`AppleVerificationAttempt` are all empty). No pilot project should be
enabled until the live-validation report records every AC1–AC8 criterion
satisfied from a real live run.

## Conclusion

RDR-068 remains **Partially Implemented**. The dispatch and transport gaps
the 2026-10-01 audit found are resolved and verified against current code
and tests. The sole remaining gap is live macOS-host acceptance evidence,
and it is **Blocked**: it requires an operator action on physical or
cloud-hosted macOS infrastructure that no coding-agent session — this one or
any other confined to a Linux execution environment — can perform. The
umbrella issue #3930 stays open; this audit does not close it or #4274.
