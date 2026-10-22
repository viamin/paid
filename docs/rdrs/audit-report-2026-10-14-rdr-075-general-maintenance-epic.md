# RDR-075 General Maintenance Runs — Epic Readiness Audit — 2026-10-14

- **Draft design:** [PR #4308](https://github.com/viamin/paid/pull/4308)
- **Umbrella:** [#4326](https://github.com/viamin/paid/issues/4326)
- **Decision:** **Do not close #4326.** RDR-075 is still Draft, its design PR
  remains open and unmerged, and required implementation and final-acceptance
  prerequisites remain open.

This audit evaluates the General Maintenance Runs epic against the draft RDR,
the repository checkout, and the live GitHub issue state. It does not treat a
filed child issue as evidence that its required behavior has shipped.

## Authority and admission

PR #4308 is open and unmerged. Its RDR specifies that implementation remains
in planning until the design and its LID artifacts are finalized and merged.
The draft also makes RDR-073's final acceptance an explicit prerequisite:
RDR-073 umbrella #4263 and closeout #4268 must complete with no required
gaps. The closeout is closed, but the umbrella and its final acceptance remain
open.

The project RDR index correctly reserves RDR-075 for General Maintenance Runs
and links to PR #4308. It does not contain the draft itself, so the draft has
not become repository authority. The unrelated historical audit reports that
refer to a former allocation of RDR-075 remain historical records and do not
describe this proposal.

## Required dependency state

The live dependency state below was refreshed on 2026-10-15.

| Requirement | Live state | Result |
| --- | --- | --- |
| RDR-073 umbrella #4263 and closeout #4268 | #4263 open; #4268 closed 2026-10-15 | RDR-073 final acceptance still blocks implementation |
| Design PR #4308 | Open, unmerged | Draft remains non-authoritative |
| M00 planning/tool-handoff #4327 | Open | LID planning and handoff validation not complete |
| M01–M06 #4328–#4333 | All open | No delivery phase has closed |
| C75 closeout #4334 | Open | Final acceptance is not eligible |
| Intent-traceability recipe #4340 | Open | Required report-only coverage has not shipped |

## Repository reconciliation

No implementation surface for this proposal is present in the checkout:

- No `RDR-075-general-maintenance-runs.md` exists under `docs/rdrs/`; the
  governing design remains only on PR #4308.
- No maintenance LLD or EARS segment exists under `docs/intent/`, so there are
  no approved `@spec` claims from which implementation tests could be traced.
- No maintenance-run goal, `maintenance_runs` feature-flag definition, report
  or finding model, recurring schedule, tool adapter, repair handoff, or
  advisory PR-audit integration is present in application code, schema, or
  specs.

Those absences are expected at this stage. They are not gaps to fill in this
audit because M00 owns the intent and RDR-073 handoff, while the later phases
own the corresponding runtime behavior.

## Rollout and tool boundaries

The draft requires `maintenance_runs` to remain default-off, with tenant opt-in
through `tenant_settings.features`; M01 owns defining and reading that flag for
manual UI/API admission and scheduled dispatch. No such behavior is currently
admitted. RDR-073's tool guard remains separately authoritative, and this
audit makes no change that could bypass its attachment, provisioning, or
hardening lifecycle.

## Required path to future final acceptance

1. Complete RDR-073 final acceptance and all required gaps.
2. Merge the RDR-075 design and create the HLD/LLD/EARS artifacts through M00.
3. Deliver M01–M06 behind the default-off `maintenance_runs` tenant guard,
   retaining RDR-073's separate authority for tools.
4. Complete #4340 and measure the draft's required external-project evidence.
5. Have C75 rerun this audit against shipped behavior, linked tests, approved
   intent, and measured evidence. Only the umbrella's final audit may close
   #4326 when no required gaps remain.

**Closure decision:** This audit tracks #4326 and intentionally does not close
the umbrella.
