---
parent: PAID
prefix: APPLE-LIVE
---

# Low-Level Design: Apple Verification Live Validation

## Purpose

Issue #3978 tracks RDR-068's live-host acceptance validation: repeated
clean-clone builds, tests, launches, and captures of the smoke iOS app,
`viamin/ColorMatching-iOS`, and a representative native macOS GUI
application through the shipped control plane; recovery convergence;
adversarial isolation and network-policy evidence; and capacity
measurement alongside three paid-agent containers, archived as a report
under `docs/rdrs/`.

That evidence cannot be produced by the ordinary test suite: it requires
a physical macOS host with Tart, an approved worker image, and the
guest executor. This segment defines the executable harness that makes
the validation repeatable, auditable, and honest. It adds no new
runtime capability to the control plane; it drives the shipped
boundaries and records what actually happened.

## Fail-closed evidence model

Every acceptance criterion maps to one or more scenarios in a frozen
suite. A scenario run produces an `Evidence` record with exactly one
status:

- `passed` — the live run observed the expected outcome.
- `failed` — the live run observed a different outcome.
- `gap` — the scenario could not be executed (missing mechanism,
  missing provider, or not attempted in this environment).

A criterion is *satisfied* in the generated report only when at least
one scenario exists for it and every scenario passed on a live run.
Anything else — failed, gap, or not executed — leaves the criterion
unmet with the reason recorded. The harness can therefore never turn a
missing run into acceptance evidence, and a report generated away from
the macOS host records gaps rather than passes.

## Scenario suite

Five groups plus the archival scenario:

- **Functional** (`AC1`–`AC3`): each target app runs as repeated clean
  clones. Each repeat provisions a fresh VM through
  `AppleVerification::Lifecycle`, dispatches a closed-protocol manifest
  (`AppleVerification::GuestProtocol` vocabulary: materialize, resolve,
  inspect, build, test, boot simulator or launch app, declarative UI
  wait, capture, export), and then destroys the VM and asserts the
  inventory is empty. Any failed operation fails the repeat; every
  repeat must pass.
- **Recovery** (`AC4`): cancellation, timeout, control-plane restart,
  host restart, partial provisioning, and orphan-discovery
  choreographies converge through the shipped lifecycle,
  reconciliation, and ledger surfaces; each moves its validating run
  out of the capacity-in-flight set first (the reconciler never claims
  an in-flight run's resources), tears down its VM, and asserts the
  terminal ledger state (intent terminal, entry active or deleted, no
  orphaned Paid-owned VM left running). The CLI lifecycle port marks
  ledger entries deleted only after its inventory confirms the
  resource is gone — it observes the shipped lane's outcome rather
  than forcing it. A mechanism the control plane does not yet provide
  (for example the 45-minute attempt timeout tracked by #3936) is
  recorded as a gap naming the missing surface, never skipped
  silently and never marked failed.
- **Isolation** (`AC5`): host SSH, host filesystem, personal data,
  keychain, devices, and container-runtime probes. Evidence comes only
  from a configured guest-diagnostics provider (the guest executor's
  `collect_diagnostics` surface observed on the live host). With no
  provider configured the scenarios record gaps.
- **Network policy** (`AC6`): adversarial probes — direct IP,
  alternate DNS, project-supplied proxy override, unsupported
  protocol — are driven through the real audited boundary
  (`AgentRuns::AppleVerification::ValidateGuestRequest`) against the
  run's resolved `GuestContract`, plus one compliant control request
  that must be permitted. Denials must record `EgressSecurityEvent`
  and `ExecutionAuditEvent` rows; the evidence row carries the denial
  reason and the audit references.
- **Capacity** (`AC7`): samples host free disk, free memory, active
  Apple VMs, and concurrent paid-agent containers while the functional
  scenarios run; degraded samples (a failed or partial host-readiness
  report) are excluded, and passes only when every complete sample
  meets the RDR-068 admission defaults (at least 60 GiB free disk, at
  least 25% free memory, at most one active Apple VM) with at least
  three agent containers active. The measured figure is recorded in
  the evidence; if no complete sample exists the scenario records a
  gap instead of failing or raising.
- **Reporting** (`AC8`): the report archival scenario passes only when
  the harness actually wrote the report file under `docs/rdrs/`.

## Ports

The runner depends on injected ports rather than host-specific
details: a lifecycle port (provision/destroy/inventory), a dispatcher
port (manifest in, operation results out), a guest-diagnostics port, a
capacity sampler port, a reconciler port, and a timeout-policy port.
`bin/apple-verify-live` wires the production ports from the shipped
control-plane objects; specs wire fakes. Missing optional ports
degrade to gaps, which is the desired behavior when the surrounding
issues (#3936, #3937, #3940, #3941) have not landed yet.

## Report

`AppleVerification::LiveValidation::Report` renders the Markdown
report destined for `docs/rdrs/live-validation-<date>-rdr-068.md`:
run metadata (host facts, repeats, control-plane revision), the
criterion status table, per-group evidence tables, and a gap section
that the next RDR-068 closeout must reconcile. The report is
regenerated per run; the archive convention and cross-reference
requirements live in the runbook (`docs/rdrs/live-validation-runbook-rdr-068.md`).

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Fail-closed criterion satisfaction | Acceptance evidence must come only from live passes; otherwise the tracker could be closed on paper. | Mark criteria satisfied when code exists, which is exactly what the 2026-09-22 audit rejected. |
| Drive only shipped control-plane boundaries | The validation must exercise what ships, not a parallel path that could pass while production code fails. | Bespoke VM scripts, which would validate nothing about the control plane. |
| Network probes through the real validator | Denial behavior and audit writes are the acceptance evidence; re-implementing them would test a copy. | Asserting against fixtures, which proves nothing live. |
| Isolation evidence via a diagnostics provider | The guest protocol is closed-vocabulary by design; the harness must not add shell access to read guest state. | Running shell probes from the harness, which would violate RDR-068's own trust boundary. |
| Gaps for missing mechanisms | The harness runs today, before #3936/#3937/#3940/#3941 land, and records exactly what is missing. | Failing the suite on unshipped dependencies, which would block all evidence collection. |

## Relationships

- Consumes `docs/intent/apple-verification-workers/` (lifecycle),
  `docs/intent/apple-guest-execution/` (protocol and dispatch), and
  `docs/intent/apple-verification-network-policy/` (contract and
  request validation) without changing them.
- Produces the `docs/rdrs/` evidence tracked by issue #3978 and
  consumed by the next RDR-068 closeout audit.
