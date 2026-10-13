# RDR-075 Implementation Status Audit — 2026-10-12

- **RDR**: RDR-075: Layered Verification Add-On (Defense in Depth) for Paid — held for human review in [#4364](https://github.com/viamin/paid/pull/4364); not yet merged into `main`. Status remains **Draft**.
- **Umbrella**: [#4365](https://github.com/viamin/paid/issues/4365) (open; this audit `Tracks` it and does not close it)
- **Phase issues**: [#4366](https://github.com/viamin/paid/issues/4366) (Phase 1 — host substrate, obligation store, layer contract), [#4367](https://github.com/viamin/paid/issues/4367) (Phase 2 — coordinator, selection rubric, evidence model), [#4368](https://github.com/viamin/paid/issues/4368) (Phase 3 — remaining layers, three entry paths, review package, finding synthesis), [#4369](https://github.com/viamin/paid/issues/4369) (Phase 4 — evaluation, reconsideration, gap closeout)
- **Closeout issue**: [#4370](https://github.com/viamin/paid/issues/4370) (open, depends on Phases 1–4)
- **Result**: **Implementation has not started. The umbrella must remain open.**
  This audit is the bounded readiness audit the issue body calls for in its
  framing; it is not the epic's terminal closeout.

This audit follows the framing in the umbrella issue: "the umbrella stays open
until the closeout audit reconciles the implementation against this framing."
It reads the umbrella body, the RDR-075 source in PR #4364, and the codebase
as it stands on 2026-10-12, and records evidence-backed gaps. It does **not**
treat closed child issues as proof — there are no closed children to treat,
and the RDR itself is not merged.

## State of the RDR

| Required state | Status |
| --- | --- |
| RDR-075 merged to `main` under `docs/rdrs/RDR-075-*.md` | **Not shipped.** No `RDR-075*.md` file exists under `docs/rdrs/`. The RDR sits at [PR #4364](https://github.com/viamin/paid/pull/4364), labelled `paid-hold-review`. The umbrella body explicitly records "Status of RDR: Draft (umbrella opened during the planning phase; status changes via closeout)". |
| `lid_planning` run produces `docs/intent/layered-verification/layered-verification-design.md` and `layered-verification-specs.md` | **Not shipped.** No `docs/intent/layered-verification/` directory exists (verified by `ls docs/intent`). |
| `layered_verification_coordinator` flag added to `FeatureFlags::DEFINITIONS` | **Not shipped.** `app/services/feature_flags.rb` does not contain a `layered_verification_coordinator` entry (verified by inspection — the last entry is `marketplace_tool_sidecars` for RDR-073). The RDR's Implementation Plan assigns this to the Phase 1 implementation issue, which has not been picked. |
| Migration `db/migrate/<timestamp>_create_business_obligations.rb` and `BusinessObligation` model | **Not shipped.** No `business_obligations` table exists in `db/schema.rb` (verified — schema.rb does not list the table; `BusinessObligation` does not appear in `app/models/`). |
| `Verification::LayerContract` interface | **Not shipped.** No `app/services/verification/` directory or interface module exists. `grep -r "Verification::" app/ spec/` returns no matches. |
| `Verification::Coordinator`, `Verification::Rubric` | **Not shipped.** No coordinator or rubric service exists. The six risk-category rubric and the four-class finding taxonomy the RDR names are not implemented. |
| Cheapest deterministic layers (`linkage_freshness`, `behavioral_test`, `implementation_specification_conformance`) | **Not shipped.** No layer registration manifest or layer classes exist. The behavioral-test layer the RDR delegates to is `Tdd::Mode` plus `Projects::Readiness`, which are shipped; the RDR is explicit that the layer is a thin wrapper that the add-on adds, not a replacement. |
| Audit, design, and bootstrap entry paths | **Not shipped.** The coordinator is the substrate for all three; with no coordinator, none of the three paths exist. |
| `Inbox::VerificationFinding` items for the four finding classes (`missing_evidence`, `stale_evidence`, `drifted_obligation`, `failed_verification`) and an `Inbox::CoverageStatus` item for obligation-by-obligation coverage reports | **Not shipped.** `Inbox::Queue` (`app/services/inbox/queue.rb`) composes its existing lanes but does not list any verification-finding or coverage-status items. |
| `EARS spec` IDs `VERIFY-001` through `VERIFY-014` | **Not shipped.** The RDR's Implementation Plan assigns `VERIFY-001..014` to Phase 1 through Phase 4 implementation issues, contingent on the `lid_planning` run materializing them. Neither the LID artifacts nor the specs exist today. |

## Acceptance outcome against the umbrella framing

| Umbrella outcome (from issue body) | Evidence | Result |
| --- | --- | --- |
| Persist obligations as typed artifacts (distinct from `ChangeIntent`) | No `BusinessObligation` model, no `business_obligations` table, no `artifact_type: "business_obligation"` rows in the knowledge pipeline. `ChangeIntent` (`app/models/change_intent.rb`) is unchanged. | Not satisfied |
| Select verifiers via a six-category rubric producing materially different plans for materially different obligations | No `Verification::Rubric` exists; no structural test can fail if the rubric collapses to a single layer set. | Not satisfied |
| Schedule verifiers through the existing `agent_harness` run infrastructure | No `Verification::Coordinator` exists; no `agent_harness` integration for verifier plans. | Not satisfied |
| Model evidence as content-addressed by obligation claim | No `Verification::Evidence` model or content-addressed scheme. | Not satisfied |
| Synthesize coverage by obligation (MET / NOT MET / UNKNOWN with contributing verifiers and freshness) | No `Verification::Coverage` record, no report shape. | Not satisfied |
| Distinguish four finding classes with class-distinct Inbox actions; failed verification cannot be cleared by re-running with a different prompt | No finding-class taxonomy or Inbox items. | Not satisfied |
| Support three entry paths (design, audit, bootstrap) using the same coordinator | No coordinator; no entry paths. | Not satisfied |
| Mandatory host policies (CI, security, code review, branch protection, conformance-with-approved-design) unchanged regardless of the flag | The host policies are unchanged today (no flag exists yet). The RDR's Rollout Guard preserves that contract explicitly. | Preserved by absence of the flag |

## Why implementation has not started

The umbrella body is explicit: "The next run is `lid_planning` (RDR-051
capability 4) converting this RDR into LID artifacts at
`docs/intent/layered-verification/`. The EARS claims use the `VERIFY-001`..
`VERIFY-014` prefix as advertised in the RDR's Implementation Plan. Until the
LID conversion has run, the implementation issues are explicitly tentative on
EARS claim ids and adopt the `VERIFY-###` ids only after the LID Planning PR
lands. The implementing agents update the `@spec` annotations when those ids
resolve."

In other words, the LID Planning PR is the prerequisite for the Phase 1
implementation PR, which in turn is the prerequisite for the four phase PRs.
The Phase 1 implementation PR is also the issue the RDR names as the owner of
the `layered_verification_coordinator` flag entry. Until that PR lands, the
rollout guard is vacuously satisfied — the coordinator and its layers do not
exist, so the guard has nothing to gate.

The umbrella body also records that the RDR is held for human review in
PR #4364. The umbrella framing in the issue body is intentionally designed to
open during the planning phase: "Status of RDR: Draft (umbrella opened during
the planning phase; status changes via closeout)". This audit records that
the planning phase has not yet concluded; the RDR is still Draft.

## Required gaps and prerequisites

No duplicate child issues were filed. Each phase already has one focused open
owner under the umbrella:

- **#4366** (Phase 1 — host substrate, obligation store, layer contract) —
  blocked on the LID Planning PR landing and the RDR merging.
- **#4367** (Phase 2 — coordinator, selection rubric, evidence model) —
  blocked on #4366.
- **#4368** (Phase 3 — remaining layers and three entry paths) — blocked on
  #4367.
- **#4369** (Phase 4 — evaluation and reconsideration) — blocked on #4368.
- **#4370** (closeout) — blocked on #4366–#4369.

The umbrella body does not enumerate a separate "LID Planning" issue; that
work is the natural next concrete PR after this audit lands and the RDR
merges. Operators may choose to file a tracking issue for the LID Planning
PR explicitly, but it is not required by the current umbrella body.

## Bounded corrections

This audit makes **no** code or schema corrections. The RDR-075 rollout
guard is vacuously effective (no flag, no coordinator, no obligation store);
introducing any of them ahead of the RDR merging would invert the guard
order — the brief is explicit that "the lid_planning run that converts the
RDR into LID artifacts is the next concrete step; implementation issues
ship behind the rollout guard below." Adding a flag entry, a migration, a
model, or a coordinator without the RDR being accepted would also
contradict the umbrella body's claim that "implementation issues are
explicitly tentative on EARS claim ids and adopt the `VERIFY-###` ids only
after the LID Planning PR lands."

## Rollout guard disposition

**Disposition: pending and vacuously satisfied.** No `layered_verification_coordinator`
flag exists, so no runtime behavior is gated. The mandatory host policies
(CI, security scanners, code review, branch protection, and conformance-
with-approved-design via `IntentConformance::VerifyAtMerge`) continue to
run unchanged. No flag flip is required by this audit; the Phase 1 issue
must own both the flag entry and the runtime read path per the RDR.

## Verification

The audit's absence findings were confirmed by code and doc inspection:

- `ls docs/rdrs/RDR-075*.md` returns nothing.
- `ls docs/intent/layered-verification/` returns nothing.
- `grep -r "layered_verification_coordinator" app/ spec/ config/` returns
  nothing.
- `grep -r "BusinessObligation\|business_obligation" app/ db/ spec/` returns
  nothing.
- `grep -r "Verification::" app/ spec/` returns nothing (other than unrelated
  substring matches under `AppleVerification::*` (e.g. `AppleVerification::Bundles`,
  `AppleVerification::Lifecycle`), full-namespace matches inside `AgentRuns::Verification`
  (MCP provisioner labels) and `Reviews::Verification` (the control-plane review
  pipeline); none of those are RDR-075 surfaces).
- `db/schema.rb` does not list a `business_obligations` table.
- The umbrella body's four phase issues (#4366, #4367, #4368, #4369) and
  closeout issue (#4370) are all open on GitHub; none has been picked.

No Ruby or RSpec execution was attempted because this audit introduces no
behavioral changes; nothing here could regress a test.

## Closure decision

Do **not** close #4365. The RDR remains in Draft (held for human review in
PR #4364), the LID conversion has not produced `docs/intent/layered-verification/`,
and no phase implementation has shipped code, tests, or migrations. The
umbrella must rerun this audit (or its terminal closeout) against the
then-current code, tests, documentation, and rollout-guard evidence after
the LID Planning PR lands, the RDR merges, and the four phase PRs ship
their EARS-anchored work. This audit records the GitHub-visible outcome as
`Tracks #4365`; it intentionally uses no closing language.
