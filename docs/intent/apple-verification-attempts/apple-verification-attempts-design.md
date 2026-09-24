---
parent: PAID
prefix: APPLE-ATTEMPT
---

# Low-Level Design: Apple Verification Attempt Lifecycle

## Purpose

This segment defines how a queued Apple verification attempt becomes an
executed, classified, and recovered guest run: admission and capacity, the
ordered execution lifecycle, source and credential transfer, failure
classification, lifecycle-gate enforcement, and worker recovery. The worker
contract (profiles, workflow revisions, attempt records, waivers) lives in
`docs/intent/apple-verification-workers/`; the guest image catalog and the
deterministic guest protocol live in `docs/intent/apple-guest-execution/`; the
guest network boundary lives in
`docs/intent/apple-verification-network-policy/`. Nothing here places an agent
or harness in the guest: the guest hosts only the trusted deterministic
executor and untrusted project code (RDR-068 security invariants 1, 5, and 6),
and approval of a workflow never makes project verification code trusted.

## Admission and capacity

The first deployment schedules at most one active Apple verification VM, with
operator-configurable admission thresholds:

| Resource | Default |
|---|---:|
| Active Apple verification VMs | 1 |
| Minimum free host disk before clone | 60 GiB |
| Minimum system memory free | 25% |
| Minimum free guest disk | 15 GiB |
| Attempt timeout | 45 minutes |

Paid also refuses admission during sustained critical memory pressure. While a
job runs, disk and memory are rechecked: crossing a normal admission threshold
stops new work, but a running attempt is terminated only for an actual
host-safety condition. When the worker slot is occupied, attempts queue fairly
by account and project and expose queue position and cancellation. Queue depth,
runtime, retry count, retained storage, and attempts per agent run are
operator-configurable limits.

Capacity exhaustion and infrastructure timeout are infrastructure results,
never code failures (see failure classification below).

## Attempt execution lifecycle

Every attempt runs against a clean clone of an approved immutable image and
follows one ordered contract:

1. Validate project approval, workflow state, source identity, capabilities,
   policy, and quota — before any capacity is reserved.
2. Reserve capacity and record a provisioning intent in the external-resource
   ledger (per `AppleVerification::Lifecycle`, APPLE-WORKER-010).
3. Clone and start the VM through the trusted host service.
4. Establish the dedicated guest GUI session and the deterministic-executor
   channel.
5. Transfer and verify source and job manifests.
6. Execute structured operations and stream safe state transitions.
7. Upload the output manifest and artifacts (results contract in
   `docs/intent/apple-verification-results/`).
8. Revoke credentials and disable the attempt's network authority.
9. Destroy a successful VM immediately.
10. Retain a failed VM for at most the configured window (default one hour),
    or destroy it early on request.

Attempts use the explicit states `queued`, `provisioning`, `running`,
`succeeded`, `failed`, `cancelled`, `timed_out`, and `unavailable`; only the
last five are terminal. Cancellation is available while an attempt is not
terminal, and a rerun is an idempotent queued retry bound to its terminal
source attempt (APPLE-VERIFY-006).

## Source and credential transfer

For committed source, Paid supplies the exact commit identity plus a
short-lived GitHub App installation credential scoped read-only to the target
repository. The credential is delivered through Paid's credential lane and is
never stored in repository configuration, artifacts, VM images, or host-service
arguments.

For uncommitted source during agent iteration, Paid creates a content-addressed
workspace bundle from the paid-agent container. Bundle creation excludes
credentials, caches, derived data, build outputs, and forbidden artifacts;
performs the existing secret and artifact safety checks; records a manifest and
content digest; and transfers through Paid's artifact lane without a host bind
mount. The guest verifies the digest before executing anything. The bundle is
deleted after the attempt and its retry window; Paid retains the digest, safe
manifest, provenance, and result association. A retained failed VM may contain
a private copy until its retention deadline, with credentials revoked and
network access disabled.

## Failure classification

Every terminal attempt carries a failure classification from a closed
taxonomy:

- `project_configuration`
- `compile_or_link`
- `test_assertion`
- `launch_or_ui_flow`
- `required_capture`
- `network_policy`
- `unsupported_capability`
- `capacity_or_quota`
- `worker_infrastructure`
- `cancellation_or_timeout`

Capacity exhaustion, admission refusal, and attempt timeout are classified as
infrastructure results (`capacity_or_quota`, `worker_infrastructure`,
`cancellation_or_timeout`), never as code failures. Paid may retry safe
infrastructure failures within policy; it must not silently retry deterministic
project failures or represent infrastructure failure as a code defect.

## Lifecycle-gate enforcement

Blocking behavior is tied to an approved committed workflow digest and its
approved lifecycle gate. Draft revisions and advisory checks never block: a
draft workflow may run only at the advisory `agent_iteration` gate
(APPLE-WORKER-005), and a missing or failed capture blocks only when the
approved revision marks it required and assigns it to the current gate.
Moving a workflow revision to a different gate is a binding change and
requires a new approval.

An approved required workflow at `completion_verification` may block an agent
run from reporting success; at `pull_request_verification` it may block Paid's
PR verification result. Required verification remains pending until it runs or
is explicitly waived (APPLE-WORKER-006). Required-verification enforcement
binds to the commit the agent run is shipping through the gate (the
`result_commit` threaded into `AgentRun#complete!` and into the re-invoked
completion); a verification of any other commit cannot satisfy the gate, so a
stale verification cannot leak forward when the run's actual output is a
different commit. The gate applies only when a completion has a result commit:
review and issue-creation goals do not ship committed code and must complete
without being parked for an impossible verification attempt. Paid never
silently skips required verification for committed output and never falls back
to executing project code on the host.

A run whose completion is withheld at the gate stays non-terminal and
`running`, marked with a withheld-completion record (timestamp plus the
completion payload the workflow produced). Such a run is parked by design,
not orphaned: stale-running recovery exempts it, so missing worker capacity
can never surface as a timeout failure. Once the gate is satisfied (a
succeeded attempt, an active waiver, or a relaxed gate after the operator
disables the rollout flag, switches the project mode to `off`, or supersedes
the approved revision), `AppleVerificationAttempts::CompleteWithheldRun`
re-invokes completion from the preserved payload. The waive flow invokes it
synchronously, attempt-completion code invokes it when it records a `succeeded`
attempt, and `AppleVerificationWithheldRunSweepJob` invokes it on a 5-minute
cron for every run in `AgentRun.awaiting_completion_verification` so the
flag/mode/revision-relaxation cases do not have to wait for either of the
synchronous callers to fire.

## Recovery and worker health

Provision, start, stop, destroy, retry, and reconciliation operations are
idempotent (APPLE-WORKER-010). Paid persists enough state to reconcile after a
control-plane restart, host restart, network interruption, timeout, or partial
provisioning failure; every scenario converges to a known external-resource
ledger state. Unknown or orphaned Paid-owned VMs are quarantined or destroyed
according to ledger state — never adopted as healthy without validation.

Repeated worker health failures quarantine the worker, revoke active
credentials, and stop scheduling. An operator repairs or replaces the worker
and explicitly returns it to service only after the isolation smoke test
passes.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Validate before reserving capacity | Quota, policy, and approval failures must not consume or strand worker capacity. | Clone first and fail inside the guest, which burns disk and hides configuration errors. |
| Keep capacity/timeout outcomes out of code-failure classes | Operators and agents must distinguish infrastructure defects from project defects (RDR-061). | A generic `failed` state, which invites retrying deterministic failures and blaming code for infra outages. |
| One ordered lifecycle contract | Recovery depends on knowing which step owned an attempt when interruption happened. | Per-provider lifecycles, which would make ledger reconciliation provider-specific. |

*HLD:* `docs/high-level-design.md` → isolation by default; no silent stops.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
