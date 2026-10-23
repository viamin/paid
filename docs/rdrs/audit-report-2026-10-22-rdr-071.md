# RDR-071 Closeout Audit — 2026-10-22

- **RDR**: [RDR-071: Confidence-Driven Issue Delivery and Feature Completion](RDR-071-confidence-driven-issue-delivery.md)
- **Tracks #4324** (C71; this audit does not close it)
- **Epic**: [#4309](https://github.com/viamin/paid/issues/4309) (E01) — **Tracks #4309; this audit does not close it.**
- **Follows**: [RDR Closeout Checklist](closeout-checklist.md)
- **Status decision**: **Partially Implemented**

This audit is scoped to RDR-071 only, per C71's acceptance criteria in the
[implementation tree](human-centered-inbox-implementation.md#c71--validate-confidence-driven-delivery-and-overall-feature-completion).
It re-runs the focused suite directly in this session (fresh evidence, not a
replay of the 2026-10-12/14/22 reports) and records concrete code/spec paths
for every `CONFIDENCE-DELIVERY-*` claim.

## 1. Criterion-by-criterion evidence

| EARS claim | Status | Evidence |
| --- | --- | --- |
| `CONFIDENCE-DELIVERY-001` (explicit policy snapshot; existing features keep their policy) | `[x]` | `app/services/feature_intents/run_admission.rb:52` dispatches on `feature_intent.confidence_driven?` (`FeatureIntent#delivery_policy`, `app/models/feature_intent.rb:79`); `spec/services/feature_intents/run_admission_spec.rb:145` "keeps mixed-policy features on their own admission contracts". |
| `CONFIDENCE-DELIVERY-002` (publish planning-held coherent-but-not-ready issue) | `[ ]` **Gap** | No `PublishHeldIssue`-shaped service exists under `app/services/feature_intents/` or `app/services/issues/`. `FeatureIntents::ReleaseIssue` only reconciles/releases an existing hold; it does not create one. Owner: [#4319](https://github.com/viamin/paid/issues/4319) (P10). |
| `CONFIDENCE-DELIVERY-003` (automatic release from passing scoped snapshot, no whole-feature approval) | `[x]` | `app/services/feature_intents/release_issue.rb`; `spec/services/feature_intents/release_issue_spec.rb:23` "releases only Paid's planning hold and snapshots the passing baseline"; `run_admission_spec.rb:101,115` admit/reconcile from the immutable snapshot. |
| `CONFIDENCE-DELIVERY-004` (preserve unrelated labels/holds; record scope/policy/evidence/thresholds/baseline) | `[x]` | `release_issue_spec.rb:189` "leaves a human planning hold untouched when the issue serves no confidence design"; `:113` "releases every confidence link the issue serves with one planning-hold removal". |
| `CONFIDENCE-DELIVERY-005` (same readiness/dependency contract on every admission path; missing assessment ≠ ready) | `[x]` | `run_admission_spec.rb:52,83,92` (`@spec CONFIDENCE-DELIVERY-005`, dependency/deploy/external-dependency denial), `:156` "fails closed when confidence work is missing a reconciled release or assessment". |
| `CONFIDENCE-DELIVERY-006` (idempotent reconciliation on external label edits / failed GitHub writes; expose discrepancy) | `[x]` | `release_issue_spec.rb:82` "retains a visible retry state when GitHub rejects the planning-label removal"; `:167` "removes an externally re-added planning label when every design already released"; `:179` "does not call GitHub for a fully released issue whose planning label is absent"; `:199` "reports a failed projection reconciliation without touching released evidence". |
| `CONFIDENCE-DELIVERY-007` (preserve admitted baseline; no pause/cancel solely for a later finding) | `[x]` | `spec/services/design_amendments/evaluate_impact_spec.rb:174` "routes confidence-driven assessment findings into completion-blocking forward work" (`@spec CONFIDENCE-DELIVERY-007/008`) — the run is not paused; the finding routes to forward work instead. |
| `CONFIDENCE-DELIVERY-008` (route findings to an unstarted issue or deduplicated follow-up as a completion dependency; raise for retry on assessment failure) | `[x]` | `evaluate_impact_spec.rb:188` "raises for retry without creating remote forward work when confidence assessment fails"; `:207` "reconciles all confidence findings once after routing them"; `complete_forward_work_spec.rb:140` "creates follow-up work for an affected pull request instead of editing its description". |
| `CONFIDENCE-DELIVERY-009` (admit revised ready scope or preserve started snapshot; never silently change an active run's scope) | `[x]` | `run_admission_spec.rb:127` "reconciles a changed unstarted scope before admission" (`@spec CONFIDENCE-DELIVERY-009`); `release_issue_spec.rb:102` "does not release stale scope when it changes during the GitHub reconciliation". |
| `CONFIDENCE-DELIVERY-010` (builder/review uses admitted baseline; no approval-gated amendment pause solely for later intent differences) | `[x]` | `spec/services/intent_conformance/verify_at_merge_spec.rb:256` "does not impose approval-gated amendment or verdict blockers" (`@spec CONFIDENCE-DELIVERY-010` at `:247`); `spec/services/intent_conformance/signal_spec.rb:67` "does not require approval-gated conformance for a confidence-driven feature" (`@spec CONFIDENCE-DELIVERY-010` at `:66`). |
| `CONFIDENCE-DELIVERY-011` (verify acceptance and all dependencies, including pending external writes and concurrent findings, before completion) | `[x]` | `complete_forward_work_spec.rb:168` "refuses completion until every dependency and acceptance/release check is satisfied"; `:114` "keeps a remote dependency write pending when its read-back fails"; `:126,157` dependency-adjacency correctness (`@spec CONFIDENCE-DELIVERY-011`). |
| `CONFIDENCE-DELIVERY-012` (reopen completion or create a linked completion cycle for a post-completion finding) | `[x]` | `complete_forward_work_spec.rb:184` "reopens a completed cycle when a new finding is persisted" (cycle increments, `pending_operations` cleared, dependency text appended to the remote completion issue body). |
| `CONFIDENCE-DELIVERY-013` (use feature flags where feasible; infeasible isolation must not itself pause in-flight work; activation follows release policy) | `[ ]` **Gap** | `app/services/feature_intents/complete_forward_work.rb:68` requires a reported `isolation.actual` before completion and does not reject on `feasible: false` alone (`complete_forward_work_spec.rb:168-182` exercises `feasible: false` without it blocking completion by itself), so the "infeasible isolation does not itself pause" half is shipped at the service boundary. There is no caller that supplies real flag/isolation status from the project's release policy, and no activation-reporting surface — the parameter is only exercised with test doubles. Owner: [#4321](https://github.com/viamin/paid/issues/4321) (P12). |
| `CONFIDENCE-DELIVERY-014` (automatic release requires admission, policy-specific review and completion wiring; shadow assessment alone does not change eligibility) | `[x]` | `run_admission_spec.rb:145,156,163,176,186` cover the full admission contract; RDR-070's shadow-mode guard (`docs/rdrs/RDR-070-facet-confidence-and-clarification.md:211`) remains separately enforced and unaffected by assessment alone. |
| `CONFIDENCE-DELIVERY-015` (disabling enrollment preserves snapshots/evidence/run state; no auto-release of held issues or pause of active runs) | `[x]` | `release_issue_spec.rb:155` "leaves an already-released link's immutable snapshot alone when a later design reconciles"; no code path releases a hold or pauses a run from enrollment state alone. |

Reused RDR-066/067 foundation (not new CONFIDENCE-DELIVERY claims, but required
for reconciliation per C71's fourth bullet): `spec/services/feature_intents/release_spec.rb`,
`mark_approved_spec.rb`, and `approval_readiness_spec.rb` all pass unchanged.
The approval-gated policy continues to govern features that have not been
explicitly enrolled in confidence-driven delivery; RDR-071 extends
`FeatureIntents::RunAdmission` rather than replacing or duplicating these
contracts. No RDR-066/067 acceptance criterion is claimed complete by this
RDR-071 audit — their separate policy work is out of this scope.

## 2. C71 behavioral checklist

| Checklist item | Result |
| --- | --- |
| Partial feature readiness, relevant design merge, automatic release, immutable builder context across every admission path | Covered: `run_admission_spec.rb` (holds an unreleased feature, admits only an approved repository revision, fails closed absent a recorded revision, reconciles ready held work before admission, pins baseline deterministically across multiple linked designs) and `release_issue_spec.rb` (design-merge gating, snapshot immutability). |
| Contradictory answer during execution: work continues, follow-up blocks completion, with and without flags | Covered for the non-flag path: `evaluate_impact_spec.rb:174` shows a confidence finding routed to forward work instead of pausing the run; `complete_forward_work_spec.rb:168` shows the resulting dependency blocking completion. The flagged/isolated path is only test-double-covered (`isolation: { feasible: false/true, actual: ... }`) — real flag wiring is the `CONFIDENCE-DELIVERY-013` gap above. |
| External label edits, queued-run races, GitHub failure/retry, concurrent closeout findings, both feature policies | Covered: `release_issue_spec.rb:82,167,179,199` (label edits, retry, failed reconciliation); `run_admission_spec.rb:127` (queued-run scope race); `complete_forward_work_concurrent_first_findings_spec.rb:33` "keeps concurrent first writers on one completion and routes the finding once"; `run_admission_spec.rb:145` (mixed/both policies). |
| Reconcile reused RDR-066/067 tasks without falsely claiming their separate policy work complete | Done above — the approval-gated suite passes unchanged and is cited only as retained foundation, not as RDR-071 evidence. |

## 3. Verification run

Executed directly in this session with a reachable `DATABASE_URL`/`REDIS_URL`
(prior 2026-10-14/22 audits could not reach PostgreSQL; this one could):

```text
bundle exec rspec \
  spec/services/feature_intents/ \
  spec/services/design_amendments/evaluate_impact_spec.rb \
  spec/services/intent_conformance/verify_at_merge_spec.rb \
  spec/services/capacity/run_admission_spec.rb
```

Result: **292 examples, 0 failures.**

## 4. Remaining gaps and ownership

Two RDR-071 EARS claims remain unshipped, and the RDR-070 dependency this RDR
relies on for shadow-mode/readiness evidence also has an outstanding gap. All
three already have focused owners; this audit files no duplicate issue:

- `CONFIDENCE-DELIVERY-002` (publish coherent-but-not-ready work as a
  planning-held GitHub issue) — [#4319](https://github.com/viamin/paid/issues/4319) (P10).
- `CONFIDENCE-DELIVERY-013` (wire real feature-flag/isolation status and
  activation reporting through to `CompleteForwardWork`) — [#4321](https://github.com/viamin/paid/issues/4321) (P12).
- RDR-070's representative assessment corpus and measurement evidence —
  [#4323](https://github.com/viamin/paid/issues/4323) (C70).

C71's own GitHub dependencies (`Depends on #4321`, and transitively `#4322`,
`#4323`) already express this; no new dependency text is added.

## 5. Rollout guard

RDR-071's rollout guard (explicit project policy selection, existing features
default to their approval-gated policy, automatic release only after P09–P12
integration) is unchanged by this audit. No project setting, policy snapshot,
or run state is modified. RDR-070's shadow-mode guard remains a precondition
for release and is not satisfied until the C70 gap above closes.

## 6. Closure decision

**Do not close #4324.** C71 depends on P12 (#4321), C69 (#4322), and C70
(#4323); all three remain open with real, owned gaps (`CONFIDENCE-DELIVERY-013`,
the question-exploration investigation slice, and the RDR-070 corpus,
respectively). RDR-071 is correctly recorded as **Partially Implemented** in
`docs/rdrs/README.md` and in RDR-071's own Metadata/Implementation Status.

**Tracks #4309.** This audit does not close the epic. Separately, this audit
found that [PR #4567](https://github.com/viamin/paid/pull/4567) closed #4309
on 2026-10-22 using `Closes #4309`, even though the audit report bundled in
that same PR (`audit-report-2026-10-22-human-centered-inbox-epic.md`)
concluded "Do not close #4309" and the same gaps (`CONFIDENCE-DELIVERY-002`,
`013`, RDR-070 corpus) remain open today. That closure contradicts the
closeout checklist's rule that only a final audit with no required gaps may
close the umbrella, and contradicts the repeated non-closing verdicts recorded
on #4309 through 2026-10-14. This audit recommends reopening #4309 as a correction, not as
a new final-acceptance claim; E01's own future final audit still decides
closure once P10/P12/C69/C70 resolve.
