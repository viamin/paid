# RDR-068 Live Validation Runbook (issue #3978)

This runbook tells a Paid operator how to produce the live-host
acceptance evidence that issue #3978 tracks: repeated clean-clone
builds, tests, launches, and captures of the smoke iOS app,
`viamin/ColorMatching-iOS`, and a representative native macOS GUI
application; recovery convergence; adversarial isolation and
network-policy evidence; and capacity alongside three paid-agent
containers. The harness is `bin/apple-verify-live`; the report it
writes is archived under `docs/rdrs/` and cross-referenced from the
next RDR-068 closeout.

The 2026-09-22 closeout audit
([audit-report-2026-09-22-rdr-068.md](audit-report-2026-09-22-rdr-068.md))
recorded the absence of exactly this evidence as gap 1. Live
validation must pass before the `apple_verification_workers` rollout
flag broadens from default-off and before flag cleanup is performed.

## Harness model

- The scenario matrix and fail-closed evidence rules live in
  `AppleVerification::LiveValidation::Suite` (one scenario per bullet of
  the issue's acceptance criteria, `AC1`–`AC8`).
- `AppleVerification::LiveValidation::Runner` executes scenarios only
  through shipped control-plane boundaries: `AppleVerification::Lifecycle`
  and the trusted host service for VM lifecycle, the
  `GuestProtocol`/`ExecuteGuestJob` admission path for guest dispatch,
  and `AgentRuns::AppleVerification::ValidateGuestRequest` for network
  denials with their audit events.
- Anything the live host cannot execute — no diagnostics provider, no
  timeout enforcement yet (#3936), no guest executor — is recorded as a
  **gap**, never a pass. A criterion is satisfied only when every one of
  its scenarios passed on a live run.

## Preflight (once per host)

1. Complete the operator setup for the macOS worker host: Tart and
   Softnet installed, the base image built, Xcode and Simulator
   runtimes installed, the trusted host service registered, and the
   isolation smoke test passing (tracked by #3941).
2. Export the host-service and guest-executor credentials the control
   plane uses:
   - `APPLE_VERIFICATION_HOST_URL`
   - `APPLE_VERIFICATION_HOST_TOKEN`
   - `APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN`
3. Enable the `apple_verification_workers` flag for the validation
   project (pilot projects only, per the RDR-068 rollout guard).
4. Publish and promote an `AppleVerificationImage` (candidate → active
   after its smoke test) and note its digest.
5. Confirm the control plane reaches the database (`DATABASE_URL`).

Then, without executing anything:

```bash
bin/apple-verify-live --plan
```

This prints the scenario matrix and the preflight result. Fix every
preflight finding before running; the harness refuses `--run` while
preflight fails.

## Executing the suite

```bash
bin/apple-verify-live --run \
  --project <paid-project-id> \
  --image <active-image-digest> \
  --profile ios-standard \
  --repeats 3
```

- `--repeats 3` reruns each functional scenario as three clean clones
  (fresh VM per repeat, destroyed and inventoried-empty after each).
- The harness writes `docs/rdrs/live-validation-<date>-rdr-068.md` and
  refuses to overwrite an existing report; archive or `--out` first.
- Use `--stdout` to preview the report without archiving.

### Isolation evidence (AC5)

The guest protocol is closed-vocabulary by design, so the harness never
runs shell text inside the guest. Isolation evidence comes from the
guest executor's diagnostics endpoint:

```bash
bin/apple-verify-live --run ... --guest-diagnostics https://<guest-executor>/diagnostics
```

The endpoint must answer each probe id (`isolation-host-ssh`,
`isolation-host-filesystem`, `isolation-personal-data`,
`isolation-keychain`, `isolation-devices`,
`isolation-container-runtime`) with `{"status":"denied"|"exposed",
"detail":"..."}`. Without the endpoint the scenarios record gaps.

For the manual cross-check, observe on the host while a functional
scenario runs: `tart list` shows only the Paid-owned VM; no Softnet
interface exposes host SSH; no host directory is shared into the VM.

### Network-policy evidence (AC6)

The harness drives the four adversarial probes (direct IP, alternate
DNS, proxy override, unsupported protocol) plus one compliant control
request through the real audited validator against the run's resolved
guest contract. Denials are expected to write `EgressSecurityEvent`
(`source_layer: apple_guest`) and `ExecutionAuditEvent`
(`apple_guest.network_policy.denied`) rows; their ids are recorded in
the evidence. Confirm on the gateway that the guest's live dependency
traffic produced the matching denials.

### Capacity evidence (AC7)

Start three active paid-agent containers (three queued agent runs are
enough), then run the suite. The sampler reads host disk/memory from
the host-service readiness report and counts running
`paid.agent_run_id`-labeled containers; every sample must meet the
RDR-068 admission defaults (≥ 60 GiB disk free, ≥ 25 % memory free,
≤ 1 active Apple VM) with ≥ 3 agent containers active. The measured
figure is recorded in the evidence row.

### Recovery evidence (AC4)

- Automated: cancellation, control-plane restart (idempotent
  re-provision), host restart (stopped VM cleaned through
  reconciliation), partial provisioning, and orphan discovery all
  converge through the shipped lifecycle/reconciliation surfaces and
  assert terminal ledger state.
- The timeout scenario records a gap until #3936 ships attempt-timeout
  enforcement; re-run the suite once it lands. For the manual variant,
  interrupt a running attempt at the deadline and confirm convergence.
- For a genuine control-plane or host restart, stop the control-plane
  service (or the host) mid-run, restore it, then rerun the suite; the
  reconciliation evidence rows confirm the ledger converged.

## Archival and closeout

1. Commit the generated report under `docs/rdrs/`.
2. Record the run in the next RDR-068 closeout: every criterion the
   report marks unmet stays a gap; do not broaden the rollout flag or
   perform `apple_verification_workers` cleanup while any criterion is
   unmet.
3. If the harness itself changed the outcome (a bug in the suite, a
   wrong threshold), fix the harness in the same PR and rerun — never
   edit an archived report by hand.

## Interpreting statuses

| Report status | Meaning |
|---|---|
| `passed` | The live run observed the expected outcome. |
| `failed` | The live run observed a different outcome — investigate on the host before rerunning. |
| `gap` | Not executable in this environment (missing mechanism or provider); the row names what is missing. |
