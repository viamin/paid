# RDR-075 Final-Acceptance Audit — 2026-10-13

- **RDR**: RDR-075: Layered Verification Add-On (Defense in Depth) for Paid — held for human review in [#4364](https://github.com/viamin/paid/pull/4364); not yet merged into `main`. Status remains **Draft**.
- **Umbrella**: [#4365](https://github.com/viamin/paid/issues/4365)
- **Phase issues**: [#4366](https://github.com/viamin/paid/issues/4366) (Phase 1 — host substrate, obligation store, layer contract), [#4367](https://github.com/viamin/paid/issues/4367) (Phase 2 — coordinator, selection rubric, evidence model), [#4368](https://github.com/viamin/paid/issues/4368) (Phase 3 — remaining layers, three entry paths, review package, finding synthesis), [#4369](https://github.com/viamin/paid/issues/4369) (Phase 4 — evaluation, reconsideration, gap closeout)
- **Closeout issue**: [#4370](https://github.com/viamin/paid/issues/4370)
- **Result**: **Final acceptance is not yet eligible. The umbrella remains open.** No RDR-075 implementation has shipped, no `docs/intent/layered-verification/` LID segment exists, and the `layered_verification_coordinator` rollout guard is vacuously satisfied because the coordinator itself does not yet exist.

This audit applies the [RDR Closeout Checklist](closeout-checklist.md) to the
RDR-075 umbrella final acceptance. It uses the umbrella body ([#4365](https://github.com/viamin/paid/issues/4365)),
the RDR-075 source in [PR #4364](https://github.com/viamin/paid/pull/4364),
the 2026-10-12 readiness audit
([`audit-report-2026-10-12-rdr-075.md`](audit-report-2026-10-12-rdr-075.md)),
the four phase issues and the closeout issue, and the working tree as
evidence. Closed child issues are **not** treated as implementation
evidence; only code, tests, migration state, and shipped documentation count.

## 1. Acceptance criteria, evidence, and verdict

The umbrella body enumerates seven shipping criteria. Each is verified against
the working tree below. None has shipped evidence.

| # | Acceptance criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Persist obligations as typed artifacts (distinct from `ChangeIntent`) with mandatory host policies unchanged | **Not satisfied.** No `BusinessObligation` model under `app/models/`, no `business_obligations` table in `db/schema.rb`, no `artifact_type: "business_obligation"` rows in the knowledge pipeline. `ChangeIntent` (`app/models/change_intent.rb`) is unchanged. The host policies (CI, security, code review, branch protection, `IntentConformance::VerifyAtMerge`) are unchanged from the absence of any flag, so they remain unconditionally effective. | `ls app/models/*obligation*` returns nothing; `rg -n "business_obligation" db/schema.rb` returns nothing; the RDR Implementation Plan assigns the obligation persistence to Phase 1 (#4366), which remains blocked. |
| 2 | Select verifiers via a six-category rubric that produces materially different plans for materially different obligations | **Not satisfied.** No `Verification::Rubric` exists. The umbrella body names six rubric categories (security, code health, behavioral, conformance, freshness, human-judgment); no segment models them. The structural test the rubric enables ("a structural test can fail if the rubric collapses to a single layer set") cannot exist yet. | `rg "Verification::Rubric\|Verification::LayerContract" app/ spec/` returns nothing; `bin/coherence-check.mjs` reports zero `VERIFY-*` annotations because no `VERIFY-001..VERIFY-014` specs exist. |
| 3 | Schedule verifiers through the existing `agent_harness` run infrastructure (one run drives multiple verifier slots; not every obligation needs every layer) | **Not satisfied.** No `Verification::Coordinator` exists. The `agent_harness` integration for verifier plans is unimplemented. | `rg "Verification::Coordinator" app/ spec/` returns nothing; no obligation scheduling code under `app/`. |
| 4 | Model evidence as content-addressed by obligation claim so a single claim change invalidates only that claim's evidence | **Not satisfied.** No `Verification::Evidence` model, no content-addressed scheme, no support tables in `db/schema.rb`. | `ls db/migrate/*business_obligation*` returns nothing; `rg "Verification::Evidence" app/ db/` returns nothing. |
| 5 | Synthesize coverage by obligation (MET / NOT MET / UNKNOWN with contributing verifiers and freshness) | **Not satisfied.** No `Verification::Coverage` record, no report shape, no Inbox surfacing for obligation-by-obligation coverage. | `rg "Verification::Coverage\|CoverageStatus" app/` returns nothing; `Inbox::Queue` (`app/services/inbox/queue.rb`) is unchanged. |
| 6 | Distinguish four finding classes (`missing_evidence`, `stale_evidence`, `drifted_obligation`, `failed_verification`) with class-distinct Inbox actions; failed verification cannot be cleared by re-running with a different prompt | **Not satisfied.** No finding-class taxonomy. No `Inbox::VerificationFinding` items, no class-distinct actions, no rule preventing prompt-only clears. | `rg "VerificationFinding\|missing_evidence\|failed_verification" app/` returns nothing. |
| 7 | Support three entry paths (design, audit, bootstrap) using the same coordinator | **Not satisfied.** All three paths require the coordinator; with no coordinator, none of the three exists. The design entry path would compose with RDR-053 `create_feature`, the audit entry path would compose with `IntentConformance::*`, and the bootstrap entry path would compose with the inbox queue — all three compositions are absent. | `rg "Verification::Entry\|entry_paths" app/` returns nothing. |
| 8 | `layered_verification_coordinator` flag added to `FeatureFlags::DEFINITIONS`, off by default; mandatory host policies unchanged regardless | **Vacuously satisfied (rollout guard preserved).** No flag entry exists. The last entry in `app/services/feature_flags.rb` is `marketplace_tool_sidecars` (RDR-073), confirmed by `rg "^\s*name: :" app/services/feature_flags.rb`. Adding the flag without the RDR accepting would invert the guard order, so #4366 (Phase 1) must own both the entry and the runtime read path per the RDR. | `app/services/feature_flags.rb` last entry is `marketplace_tool_sidecars`; `rg "layered_verification_coordinator" app/ spec/ config/` returns nothing. |

## 2. Verification re-run

This audit re-verifies the prior 2026-10-12 readiness audit's findings against
the current working tree (branch `paid/4365-rdr-075epic-layered-verification-add-on-defense-in-6e64d3`,
based on `main` at `71f2720`). No Ruby or RSpec execution was attempted
because this audit introduces no behavioral changes; the structural checks
below do not depend on database reachability and are sufficient to confirm
that no new code has shipped since the 2026-10-12 audit.

```
node bin/coherence-check.mjs       # 2026-10-13
```

Result summary: no `VERIFY-001`..`VERIFY-014` annotations exist (the
`docs/intent/layered-verification/` segment the LID Planning PR would
produce is absent). The `@spec` set on `main` (1103 unique IDs) is unchanged
in shape: pre-existing reverse orphans (`CREATE-FEATURE-001..004`,
`FEAT-NAME-001`) and uncovered `[ ]` gaps in unrelated segments (`ACCOUNT-QUEUE-*`,
`APPLE-RESULT-*`, `CONFIDENCE-DELIVERY-*`, etc.) are unchanged from the
prior run and outside RDR-075 scope.

```
rg -n 'business_obligation|BusinessObligation' app/ db/                        # 0
rg -n 'Verification::(Coordinator|Rubric|LayerContract|Evidence|Coverage|Finding|Entry)' \
                                                app/ spec/                    # 0
rg -n 'layered_verification_coordinator'    app/ spec/ config/                # 0
rg -n 'VERIFY-0(0[1-9]|1[0-4])'              app/ spec/ docs/                 # 0
ls docs/intent/layered-verification                                              # ENOENT
ls db/migrate/*business_obligation*                                              # ENOENT
ls app/services/verification                                                     # ENOENT (no RDR-075 namespace)
ls app/services/verification                                                      # directory absent under app/services
```

`ls app/services` confirms that `apple_verification/`, `apple_verification_attempts/`,
`apple_verification_workers/`, and `apple_verification_workflow_revisions/`
remain the only `verification`-named directories — none of them is an
RDR-075 surface. There is no `app/services/verification/` namespace, no
`Verification::*` class beyond the apple-verification tree, and no
`business_obligation*` migration, model, controller, view, or spec.

```
curl -sf "$GITHUB_API_URL/repos/viamin/paid/pulls/4364" -H "X-Agent-Run-Id: …" \
                                                            -H "X-Proxy-Token: …"
```

PR #4364 is still open, holds the `paid-hold-review` label, and changes only
`docs/rdrs/RDR-075-layered-verification-defense-in-depth.md`
(additions: 964) and `docs/rdrs/README.md` (one-line index change). The RDR
itself has not landed on `main`.

```
for issue in 4366 4367 4368 4369 4370; do
  curl -sf "$GITHUB_API_URL/repos/viamin/paid/issues/$issue" …
done
```

All four phase issues (#4366–#4369) remain **open** with labels `P1, planning`;
the closeout issue (#4370) remains **open** with labels `quality, P1`. None
of them has a merged PR. The `planning` label on the phase issues is
appropriate per the closeout checklist step 6 (the phases need authoritative
LID conversion before implementation). The `quality` label on #4370 is not in
the default auto-pick skip set and does not block pickup.

The grep results above, the coherence-check output, the GitHub API state,
and the 2026-10-12 readiness audit all reach the same conclusion: no
RDR-075 claim that was absent on 2026-10-12 has shipped code, migration,
or test evidence between then and this audit. None of the prior absence
findings has flipped; none of the prior vacuous-satisfaction findings
needs updating.

## 3. Gap ownership and reconciliation

Every unmet acceptance area already has a focused, open, correctly-scoped
child issue under umbrella #4365, per the umbrella body's table:

| Acceptance area | Open owner |
| --- | --- |
| Persistence host substrate, obligation store, layer contract | [#4366](https://github.com/viamin/paid/issues/4366) (Phase 1) |
| Coordinator, selection rubric, evidence model | [#4367](https://github.com/viamin/paid/issues/4367) (Phase 2) |
| Remaining layers, three entry paths, review package, finding synthesis | [#4368](https://github.com/viamin/paid/issues/4368) (Phase 3) |
| Evaluation, reconsideration, gap closeout | [#4369](https://github.com/viamin/paid/issues/4369) (Phase 4) |
| RDR validation, rollout-guard review, README index reconciliation | [#4370](https://github.com/viamin/paid/issues/4370) (Closeout) |

The umbrella body does not enumerate a separate "LID Planning" issue; that
work is the natural next concrete PR after this audit lands and the RDR
merges, and it must produce `docs/intent/layered-verification/` LLD/EARS
artifacts and the `VERIFY-001`..`VERIFY-014` EARS claims the phase issues
will reference. No new child issue is filed: each phase already has a
single-focus, independent, pickable owner, and the closeout issue
(#4370) is already owned.

## 4. Rollout-guard disposition

| Required guard | Disposition |
| --- | --- |
| `layered_verification_coordinator` flag defined in `FeatureFlags::DEFINITIONS`, default-off, opt-in via `FeatureFlags.enabled?(:layered_verification_coordinator, project:)` | **Pending and vacuously satisfied.** No flag entry exists, so no runtime behavior is gated. The mandatory host policies (CI, security scanners, code review, branch protection, `IntentConformance::VerifyAtMerge`) continue to run unchanged. #4366 (Phase 1) must own both the flag entry and the runtime read path per the RDR; flagging ahead of the RDR accepting would invert the guard order and contradict the umbrella body's "implementation issues are explicitly tentative on EARS claim ids and adopt the `VERIFY-###` ids only after the LID Planning PR lands" framing. |
| Mandatory host policies (CI, security, code review, branch protection, conformance-with-approved-design) unchanged regardless of the flag | **Preserved by absence.** All five host policies continue to run unmodified today; the rollout guard is satisfied because there is no coordinator behavior to bypass them. |

No shipped behavior bypasses the rollout guard.

## 5. Required next steps before a terminal closeout can run

A future final acceptance audit may close #4365 only after all of the
following hold:

1. The RDR-075 PR (#4364) merges to `main`, producing
   `docs/rdrs/RDR-075-layered-verification-defense-in-depth.md`; the RDR's
   `Metadata: Status` advances to `Accepted` and the `## Rollout Guard`
   section is recorded against the merged file.
2. A `lid_planning` run produces the authoritative LID artifacts at
   `docs/intent/layered-verification/layered-verification-design.md` and
   `docs/intent/layered-verification/layered-verification-specs.md`,
   materializing the `VERIFY-001`..`VERIFY-014` EARS claims the RDR's
   Implementation Plan advertises.
3. Phase 1 (#4366) ships: the `BusinessObligation` model, the
   `business_obligations` migration, the `artifact_type: "business_obligation"`
   mirror in the knowledge pipeline, the `Verification::LayerContract`
   interface, the `layered_verification_coordinator` flag entry, and the
   earliest deterministic layers (`linkage_freshness`,
   `behavioral_test`, `implementation_specification_conformance`).
4. Phase 2 (#4367) ships: the `Verification::Coordinator`, `Verification::Rubric`
   (six categories), `Verification::Evidence` (content-addressed by claim),
   and `Verification::Coverage` models.
5. Phase 3 (#4368) ships: the remaining layers, three entry paths,
   finding synthesis into `Inbox::Queue` with class-distinct actions, and
   the review package.
6. Phase 4 (#4369) ships: the evaluation harness and the reconsideration
   review that confirms or rejects Alternative A (re-scope to standalone).
7. Closeout (#4370) runs the [RDR Closeout Checklist](closeout-checklist.md)
   against shipped code and tests rather than against closed-issue state,
   updates the RDR's `Metadata: Status` and `Implementation Status` sections
   to `Implemented` (or `Partially Implemented` if any criterion remains
   unmet), advances the `marketplace_tool_sidecars`-sorted RDR README index
   to include RDR-075, and reconciles the label hygiene step.
8. This audit's verification section can rerun against the then-current code
   with the project's PostgreSQL service reachable and report
   database-backed passing evidence for every acceptance criterion in the
   table above.

Until those eight conditions hold, #4365 remains open and the umbrella
cannot be closed with GitHub closing language.

## 6. Closure decision

**Do not close #4365.** This audit `Tracks #4365`; it is non-closing.
The GitHub-visible outcome is:

- The 2026-10-12 readiness audit (`audit-report-2026-10-12-rdr-075.md`)
  already `Tracks #4365` and is non-closing; this final audit confirms its
  findings are still valid one day later and adds the structural
  re-verification above.
- The umbrella body itself requires "the umbrella stays open until the
  closeout audit reconciles the implementation against this framing" —
  reconciliation is blocked on section 5's conditions.
- No closing PR reference such as `Closes #4365` is used; no
  `paid_state`-side closure is claimed; Paid automation remains free to
  re-pick the open children once their upstream dependencies (the LID
  Planning PR, the merged RDR) resolve.
- When the required next steps in section 5 are met, a future agent may
  run this audit again with the same template, refresh the per-phase
  evidence to match, and only then apply `Closes #4365` on a PR that
  carries the shipped evidence.

## 7. Verification appendix

All findings in this audit were confirmed by direct inspection:

- `ls docs/rdrs/RDR-075*.md` — empty (RDR has not merged).
- `ls docs/intent/layered-verification/` — empty (LID segment absent).
- `rg -n "business_obligation\|BusinessObligation" db/schema.rb` —
  no matches.
- `rg -n 'name: :' app/services/feature_flags.rb` — last entry is
  `:marketplace_tool_sidecars` (RDR-073), confirming no
  `layered_verification_coordinator` flag.
- `rg -n 'Verification::(Coordinator|Rubric|LayerContract|Evidence|Coverage|Finding|Entry)' app/ spec/`
  — no RDR-075 matches; the only `Verification::` namespaces are
  `AppleVerification::*`, which are unrelated surfaces.
- `rg -n 'VERIFY-0(0[1-9]|1[0-4])' app/ spec/ docs/` — no matches; the
  EARS claim prefix the RDR advertises does not exist anywhere yet.
- GitHub API confirms #4364 still holds `paid-hold-review`, #4365 still
  open, #4366–#4369 still open with `planning` labels, #4370 still open
  with `quality` label.

No code, schema, doc, or test was changed by this audit; no Ruby or RSpec
execution was needed.
