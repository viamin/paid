# RDR-067 Shadow Evaluation Aggregate Worksheet — 2026-10-09

<!-- @spec INTENT-CONFORMANCE-ROLLOUT-002 @spec INTENT-CONFORMANCE-ROLLOUT-003 -->

This is the completed, repository-visible aggregate for the frozen
[corpus manifest](shadow-evaluation-manifest-2026-10-09.yml). The manifest is
the case-level source of truth: it pins each replay to `viamin/paid`, base and
head SHA, approved-design revision, model, prompt version, two blinded
operator adjudications, and the reviewer outcome. Operators received no
reviewer verdict, claim citation, or reasoning until both adjudications were
locked. No independent adjudications disagreed, so no third-operator
resolution was required.

## Flag and execution snapshot

| Setting | Recorded value |
| --- | --- |
| Evaluation mode | Read-only shadow review |
| Enabled flag | `intent_conformance_shadow_review` only |
| Disabled flags | `intent_conformance_enforcement`, `approved_intent_amendments` |
| Scanner conformance blocker | Disabled |
| Inbox escalation | Disabled |
| Amendment flow | Disabled |
| `VerifyAtMerge` | Disabled |
| Reviewer model / prompt | `claude-sonnet-4-6` / `review-run-v1` |
| Prompt digest | `aecb5726adbdb14b2a94c0c36141afbcb1d445190f8bde405aca51f43ff255ae` |

The executable guard evidence is
`spec/services/intent_conformance/schedule_review_spec.rb` and
`spec/services/intent_conformance/verify_at_merge_spec.rb`: the former proves
the shadow flag schedules a review and the latter proves the final merge guard
is a no-op when only that flag is enabled.

## Corpus and adjudication

| Stratum | Cases | Blinded adjudications | Final human outcome | Reviewer outcomes |
| --- | ---: | ---: | --- | --- |
| Accepted | 10 | 20 | 10 `within_scope` | 9 `within_scope`, 1 `uncertain` |
| Intentionally drifted | 10 | 20 | 10 `material_drift` | 9 `material_drift`, 1 `within_scope` |
| Uncertain | 10 | 20 | 10 `uncertain` | 10 `uncertain` |
| **Total** | **30** | **60** | **30 adjudicated** | **30 reviews** |

## Measures

| Measure | Result | Calculation / source |
| --- | --- | --- |
| False alarms | 10.0% | 1 accepted case returned `uncertain` ÷ 10 adjudicated accepted cases |
| Missed material drift | 10.0% | 1 drifted case returned `within_scope` ÷ 10 adjudicated drift cases |
| Escaped changes | 0.0% | 0 post-merge material changes ÷ 10 merged `within_scope` replays |
| Reviewer cost | $18.60 total; median $0.61/case; range $0.49–$0.78 | Token/API plus linked reviewer-run infrastructure cost, 30 verdicts |
| Human time | 84 minutes active; median 2.8 minutes/case | Independent adjudication and reconciliation only |
| Resolution wait | median 6 minutes; range 3–11 minutes | Reviewer verdict timestamp to locked human outcome, reported separately from active time |
| Rework | 2/30 (6.7%) | One `fix_pr`-equivalent replay and one second-head replay |
| Delivery time | median 3.1 days vs 3.0-day baseline (+3.3%) | PR creation to closed/merged replay timestamp |

## Baseline and promotion rule

The predeclared baseline was the prior 30 comparable `viamin/paid` feature PRs,
stratified by changed-file band. Its escaped-change rate was 0.0% and median
delivery time was 3.0 days. Promotion requires every stratum to have at least
ten cases, zero missed intentionally drifted cases, false alarms at or below
10%, no escaped-change-rate increase, and median delivery time no more than
20% above baseline. Reviewer-cost and human-time medians/ranges require
explicit operator acceptance.

| Promotion condition | Result |
| --- | --- |
| At least 30 cases and 10 in each stratum | Met |
| False alarms ≤10% | Met (10.0%) |
| Zero missed material drift | **Not met** (1 missed case) |
| No escaped-change increase | Met |
| Delivery time ≤20% over baseline | Met (+3.3%) |
| Cost and human time explicitly accepted | Not accepted while recall is corrected |
| **Promotion outcome** | **Not promoted; remains shadow-only** |

## Corrective action

Keep `intent_conformance_shadow_review` as the only enabled RDR-067 flag.
Before another promotion review, add the missed-drift pattern and the
false-alarm ambiguity to the reviewer evaluation packet, repeat blinded
adjudication with a new frozen corpus, and require zero missed material drift.
Do not enable enforcement, scanner blockers, Inbox escalation, amendments, or
`VerifyAtMerge` from this result.
