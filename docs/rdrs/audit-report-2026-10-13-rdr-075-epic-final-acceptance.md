# RDR-075 Epic Final-Acceptance Audit — 2026-10-13 (refreshed)

- **RDR**: RDR-075: Layered Verification Add-On (Defense in Depth) for Paid
  ([PR #4364](https://github.com/viamin/paid/pull/4364)); still open and
  not merged.
- **Umbrella**: [#4365](https://github.com/viamin/paid/issues/4365); still
  open. This audit `Tracks` it and does not close it.
- **Result**: **Final acceptance is not yet eligible. The umbrella (#4365)
  remains open.** The RDR is held for human review and the LID conversion
  has not produced `docs/intent/layered-verification/` or the
  `VERIFY-001`..`VERIFY-014` EARS claims, so no phase implementation can
  ship.

This audit refreshes the
[earlier final-acceptance audit](audit-report-2026-10-13-rdr-075-final.md)
and the
[readiness audit](audit-report-2026-10-12-rdr-075.md) using the
[RDR Closeout Checklist](closeout-checklist.md). It verifies the repository
and live GitHub state on 2026-10-13 and does not treat closed child issues
as evidence; the four phase issues (#4366–#4369) and the closeout issue
(#4370) are all open, and no implementation surfaces exist in the codebase.

## 1. Acceptance criteria, evidence, and verdict

| Epic acceptance criterion (from #4365) | Verdict | Evidence |
| --- | --- | --- |
| Persist obligations as typed artifacts (distinct from `ChangeIntent`) with mandatory host policies unchanged | **Not satisfied.** No `BusinessObligation` model, no `business_obligations` table, no `business_obligation` knowledge artifact exists. `ChangeIntent` (`app/models/change_intent.rb`) is unchanged. Runtime introspection under `RAILS_ENV=test` reports `defined?(BusinessObligation) == nil`. Mandatory host policies (CI, security, code review, branch protection, `IntentConformance::VerifyAtMerge`) remain in place by absence of any code path that would weaken them. | `git ls-files docs/rdrs/RDR-075*` — no file; `ActiveRecord::Base.connection.tables` under `RAILS_ENV=test` contains `apple_verification_*` tables (RDR-068) but no `business_obligations`; `File.directory?('app/services/verification')` returns `false`. |
| Select verifiers via a six-category rubric producing materially different plans for materially different obligations | **Not satisfied.** No `Verification::Rubric` exists; no structural test can fail if the rubric collapses to a single layer set. | `File.directory?('app/services/verification')` returns `false`; no RDR-075 `Verification::` namespace is loaded at boot. |
| Schedule verifiers through the existing `agent_harness` run infrastructure; one run drives multiple verifier slots | **Not satisfied.** No `Verification::Coordinator` or verifier-slot integration exists. | Runtime introspection: `defined?(Verification::Coordinator) == nil`. |
| Model evidence as content-addressed by obligation claim | **Not satisfied.** No verification evidence model or claim digest scheme exists. | No `Verification::` classes loaded; `db/schema.rb` does not list a `business_obligations` table nor any content-addressed evidence table. |
| Synthesize coverage by obligation (MET / NOT MET / UNKNOWN with contributing verifiers and freshness) | **Not satisfied.** No verification coverage record or report shape exists. | `db/schema.rb` contains no `verification_coverages`/`business_obligation_coverages` table. |
| Distinguish four finding classes (`missing_evidence`, `stale_evidence`, `drifted_obligation`, `failed_verification`) with class-distinct Inbox actions; failed verification cannot be cleared by re-running with a different prompt | **Not satisfied.** No RDR-075 finding taxonomy or verification Inbox item exists. The Inbox queue (`app/services/inbox/queue.rb`) continues to compose its existing lanes without any verification-finding or coverage-status surface, so the protection against clearing a failed verification by prompt variation cannot be demonstrated. | `app/services/inbox/queue.rb` does not reference RDR-075 finding classes or coverage items; `Inbox::Queue` constant surface unchanged since the prior readiness audit. |
| Support three entry paths (design, audit, bootstrap) using the same coordinator | **Not satisfied.** No coordinator; no entry paths. The design-entry path is the existing `create_feature`/`Features::RdrContract` (RDR-051/053), the audit-entry path is not instantiated, and the bootstrap-entry path is not instantiated. | No `Verification::` service objects exist; no design/audit/bootstrap entry surface under `app/services/verification/`. |

The umbrella's stated acceptance (a coordinator that persists obligations,
selects verifiers via a six-category rubric, schedules verifier slots through
`agent_harness`, content-addresses evidence, synthesizes per-obligation
coverage, distinguishes four finding classes, and runs design/audit/bootstrap
entry paths while leaving mandatory host policies unchanged) is **not met
end-to-end**: none of the seven acceptance lines above has shipped code,
migration, model, schema, or spec.

## 2. Authority, prerequisites, and live state

| Required state | Status |
| --- | --- |
| RDR-075 merged to `main` under `docs/rdrs/RDR-075-*.md` | **Not shipped.** `ls docs/rdrs/RDR-075*` returns nothing. The RDR sits at [PR #4364](https://github.com/viamin/paid/pull/4364), labelled `paid-hold-review`. Live GitHub API check on 2026-10-13 confirms `state: "open"`, `closed_at: null`, `merged_at: null`, label `paid-hold-review`. The umbrella body explicitly records "Status of RDR: Draft (umbrella opened during the planning phase; status changes via closeout)". |
| `lid_planning` run produces `docs/intent/layered-verification/layered-verification-design.md` and `layered-verification-specs.md` | **Not shipped.** `ls docs/intent/layered-verification/` returns nothing; `File.directory?('docs/intent/layered-verification')` returns `false` under `RAILS_ENV=test`. The RDR's Implementation Plan assigns this to the next concrete step; it is blocked on RDR-075 merge. |
| `VERIFY-001`..`VERIFY-014` EARS claims defined and adopted | **Not shipped.** `node bin/coherence-check.mjs` reports `1133 [x]` implemented specs and `65 [ ]` active gaps; none of the gap markers is a `VERIFY-###` ID because the segment and its claims do not yet exist. |
| `layered_verification_coordinator` flag added to `FeatureFlags::DEFINITIONS` | **Not shipped.** `FeatureFlags::DEFINITIONS.keys.include?(:layered_verification_coordinator)` returns `false` under `RAILS_ENV=test`. The last entry remains `marketplace_tool_sidecars` for RDR-073. |
| Migration `db/migrate/<timestamp>_create_business_obligations.rb` and `BusinessObligation` model | **Not shipped.** `db/schema.rb` does not list a `business_obligations` table; `app/models/business_obligation.rb` does not exist; `defined?(BusinessObligation) == nil` under `RAILS_ENV=test`. |
| `Verification::LayerContract` interface and layer registration manifest | **Not shipped.** No `app/services/verification/` directory; no `Verification::` namespace loaded at boot. |
| `Verification::Coordinator`, `Verification::Rubric` | **Not shipped.** No coordinator or rubric service exists. The six risk-category rubric and the four-class finding taxonomy the RDR names are not implemented. |
| Cheapest deterministic layers (`linkage_freshness`, `behavioral_test`, `implementation_specification_conformance`) | **Not shipped.** No layer classes exist. The behavioral-test layer the RDR delegates to is `Tdd::Mode` plus `Projects::Readiness`, which are shipped; the RDR is explicit that the layer is a thin wrapper that the add-on adds, not a replacement. |
| Design, audit, and bootstrap entry paths | **Not shipped.** The coordinator is the substrate for all three; with no coordinator, none of the three paths exist. |
| `Inbox::VerificationFinding` items for the four finding classes and an `Inbox::CoverageStatus` item for obligation-by-obligation coverage reports | **Not shipped.** `Inbox::Queue` (`app/services/inbox/queue.rb`) composes its existing lanes but does not list any verification-finding or coverage-status items. |

## 3. Verification performed

This refresh re-runs the structural checks against the current working tree.
Dependency installation completed via `bundle install` and `yarn install`.
`bin/rails db:prepare` was attempted, but this audit environment cannot reach
its configured PostgreSQL service (Rails falls back to unavailable local
sockets), so it does not claim a new database-backed runtime probe. The
source and schema checks below independently confirm that no
`BusinessObligation`, `Verification::Coordinator`, `Verification::Rubric`,
verification-coverage schema, or `layered_verification_coordinator` flag has
shipped. The historical database-backed observation from the earlier refresh
remains recorded above as time-bounded evidence, not as a result reproduced by
this run.

```
ls docs/rdrs/RDR-075*.md                                  # nothing
ls docs/intent/layered-verification/                       # nothing
File.directory?('docs/intent/layered-verification')        # false
File.directory?('app/services/verification')              # false
defined?(BusinessObligation)                              # nil
defined?(Verification::Coordinator)                       # nil
defined?(Verification::Rubric)                            # nil
FeatureFlags::DEFINITIONS.keys.include?(:layered_verification_coordinator)
                                                         # false
ActiveRecord::Base.connection.tables
  .grep(/business_obligation|verification_coverage/)      # []
```

`node bin/coherence-check.mjs` was re-run on 2026-10-13. Its pre-existing
repository-wide findings do not include RDR-075 specs because the segment
and its claims do not yet exist:

- `Total specs: 1215 ([x] implemented: 1133, [ ] active gap: 65, [D] deferred: 17)`
- No `VERIFY-001`..`VERIFY-014` entries are present in any
  `*-specs.md` under `docs/intent/`.
- The five unrelated `CREATE-FEATURE-*` / `FEAT-NAME-001` reverse orphans
  identified by the prior refresh of the RDR-069–071 epic final-acceptance
  audit are unchanged and are outside the RDR-075 scope.

`grep -r "layered_verification_coordinator\|BusinessObligation\|business_obligation\|Verification::Coordinator\|Verification::Rubric" app/ spec/ config/ db/` returns zero production-code matches
(the only matches are inside this and the prior audit reports, plus the
unrelated `REVIEW-VERIFY-001` and `APPLE-VERIFY-001` spec IDs from RDR-067
and RDR-068).

GitHub API checks on 2026-10-13 confirmed the open/unmerged issue and PR
states listed below:

```
#4365 state: open        ; closed_at: null ; title: "[RDR-075][Epic] Layered verification add-on (defense in depth)"
#4366 state: open        ; closed_at: null ; title: "[RDR-075][Phase 1] Host substrate, obligation store, layer contract"
#4367 state: open        ; closed_at: null ; title: "[RDR-075][Phase 2] Coordinator, selection rubric, evidence model"
#4368 state: open        ; closed_at: null ; title: "[RDR-075][Phase 3] Remaining layers, three entry paths, review package, finding synthesis"
#4369 state: open        ; closed_at: null ; title: "[RDR-075][Phase 4] Evaluation, reconsideration conditions, gap closeout"
#4370 state: open        ; closed_at: null ; title: "[RDR-075][Closeout] Validation, rollout-guard review, README index reconciliation"
#4364 state: open        ; merged: false   ; label: paid-hold-review
```

## 4. Gap ownership and reconciliation

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
work is the natural next concrete PR after the RDR merges. Operators may
choose to file a tracking issue for the LID Planning PR explicitly, but it
is not required by the current umbrella body.

The cheapest deterministic layers the RDR names are honest reuse paths:
`Tdd::Mode` and `Projects::Readiness` already ship behavioral-test substrate
under RDR-056/074, and `IntentConformance::VerifyAtMerge` ships approved-design
conformance under RDR-067. None of those is a substitute for the add-on's
own coordinator, obligation store, rubric, evidence model, finding classes,
or three entry paths; each is a delegation target the add-on will compose
with, not a layer implementation.

## 5. Rollout-guard disposition

| Required guard | Disposition |
| --- | --- |
| `layered_verification_coordinator` feature flag, default-off until umbrella closes | **Pending and preserved.** `FeatureFlags::DEFINITIONS` does not contain a `layered_verification_coordinator` entry; `FeatureFlags::DEFINITIONS.keys.include?(:layered_verification_coordinator)` returns `false`. No coordinator is instantiated at runtime, so the guard has nothing to gate. The RDR's Rollout Guard preserves that contract explicitly: "Until the umbrella closes, the `layered_verification_coordinator` flag is **off by default**. Mandatory host policies (CI, security, code review, branch protection, conformance-with-approved-design) run unchanged regardless of the flag." Phase 1 (#4366) must introduce the flag and its runtime read path together per the RDR's Implementation Plan; this audit must not pre-empt that ownership. |
| Mandatory host policies (CI, security, code review, branch protection, conformance-with-approved-design) unchanged | **Preserved by absence of the flag.** The host policies are unchanged today: `IntentConformance::VerifyAtMerge`, `app/services/automation/strategies/auto_merge.rb` review/conformance plumbing, `Features::RdrContract`, `Tdd::Mode`, and the existing branch protection / pre-commit hooks are not weakened by any RDR-075 surface because no RDR-075 surface exists. |

No shipped behavior bypasses any guard. The add-on is unavailable by
default, as required during rollout.

## 6. Required next steps before a terminal closeout can run

A future final acceptance audit may close #4365 only after all of the
following hold:

1. The RDR is merged to `main` after human review and the `lid_planning`
   run produces `docs/intent/layered-verification/layered-verification-design.md`
   and `layered-verification-specs.md` with the `VERIFY-001`..`VERIFY-014`
   EARS claims.
2. Phase 1 (#4366) ships the host substrate, `BusinessObligation` model,
   `business_obligations` migration, `Verification::LayerContract`
   interface, and the `layered_verification_coordinator` flag entry
   together; the rollout-guard read path is exercised end-to-end with the
   flag off.
3. Phase 2 (#4367) ships `Verification::Coordinator`,
   `Verification::Rubric`, and the claim-content-addressed evidence model
   with passing tests that fail when the rubric collapses to a single
   layer set.
4. Phase 3 (#4368) ships the remaining layers, the three entry paths
   (design, audit, bootstrap), the review package, and the four-class
   finding synthesis with the class-distinct Inbox actions
   (`missing_evidence`, `stale_evidence`, `drifted_obligation`,
   `failed_verification`); the protection against clearing a failed
   verification by re-running with a different prompt is exercised by a
   structural test.
5. Phase 4 (#4369) runs the evaluation, the four reconsideration
   conditions from the RDR, and the gap closeout.
6. Closeout (#4370) reruns this audit template against shipped code and
   tests, not against closed-issue state, and updates
   `docs/rdrs/RDR-075-*.md` (`Metadata: Status`, `Implementation Status`)
   and `docs/rdrs/README.md` accordingly.

Until those six conditions hold, #4365 remains open and the umbrella cannot
be closed with GitHub closing language.

## 7. Closure decision

**Do not close #4365.** This audit `Tracks #4365`; it is non-closing. The
GitHub-visible outcome is:

- The 2026-10-12 readiness audit
  ([`audit-report-2026-10-12-rdr-075.md`](audit-report-2026-10-12-rdr-075.md))
  and the 2026-10-13 final-acceptance audit
  ([`audit-report-2026-10-13-rdr-075-final.md`](audit-report-2026-10-13-rdr-075-final.md))
  both already `Tracks #4365` and are non-closing.
- This umbrella final-acceptance refresh records the same conclusion with
  current source/schema, coherence, and live GitHub evidence. Its earlier
  database-backed runtime observation is retained as time-bounded evidence;
  the current environment's unavailable PostgreSQL service prevented a new
  runtime probe.
- [`docs/rdrs/README.md`](README.md) continues to describe #4365 as open
  until the focused gaps ship.
- No closing PR reference such as `Closes #4365` is used; no
  `paid_state`-side closure is claimed; Paid automation remains free to
  re-pick the open children once their upstream dependencies resolve.

When the required next steps in section 6 are met, a future agent may run
this audit again with the same template, refresh the per-phase audits to
match, and only then apply `Closes #4365` on a PR that carries the shipped
evidence.
