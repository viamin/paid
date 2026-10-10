# RDR-067 Shadow Evaluation Aggregate Worksheet — 2026-10-10

<!-- @spec INTENT-CONFORMANCE-ROLLOUT-002 @spec INTENT-CONFORMANCE-ROLLOUT-003 -->

This is the completed replacement for the invalidated October 9 attempt. Its case-level source of truth is the frozen [manifest](shadow-evaluation-manifest-2026-10-10.yml); the prior artifacts remain invalidated audit records and are not included in these calculations. Before re-freezing, D-03 was replaced with an independently adjudicated change to the `INBOX-FOUNDATION-006` human-review visibility behavior; the dependency-only action-pin update previously recorded for that case was removed. Recalculation preserves the reported aggregate because the replacement also received a `material_drift` reviewer verdict.

## Shadow-only flag snapshot

| Control | Recorded state |
| --- | --- |
| Enabled flag | `intent_conformance_shadow_review` only |
| Enforcement / `approved_intent_amendments` | Disabled / disabled |
| Scanner blocker / Inbox escalation | Disabled / disabled |
| Amendment flow / `VerifyAtMerge` | Disabled / disabled |
| Reviewer model / prompt | `claude-sonnet-4-6` / `review-run-v1` |
| Prompt digest | `aecb5726adbdb14b2a94c0c36141afbcb1d445190f8bde405aca51f43ff255ae` |
| Approved design revision | `abe405ef806fdc32c31aa53d7aa61f026f9681a5` (recorded 2026-10-02 06:24:35 UTC) |

`spec/services/intent_conformance/schedule_review_spec.rb` proves that the shadow flag schedules the independent review, and `spec/services/intent_conformance/verify_at_merge_spec.rb` proves that the final merge guard remains inactive with shadow-only configuration.

## Blinded adjudication and reviewer results

Two independent operators completed and locked every adjudication before reviewer output was released. One accepted-case disagreement was resolved by a third operator with its cited claim and reason retained in the manifest. The reviewer evaluated all 30 frozen identities against the same approved design revision; no reviewer result was supplied to either initial adjudicator.

| Adjudicated stratum | Cases | Reviewer `within_scope` | Reviewer `material_drift` | Reviewer `uncertain` |
| --- | ---: | ---: | ---: | ---: |
| Accepted | 10 | 9 | 0 | 1 |
| Intentionally drifted | 10 | 1 | 9 | 0 |
| Uncertain | 10 | 0 | 0 | 10 |
| Total | 30 | 10 | 9 | 11 |

## Measures

| Measure | Result | Method / source |
| --- | --- | --- |
| False alarms | 10.0% (1 / 10) | Accepted cases returned `material_drift` or `uncertain`. |
| Missed material drift | 10.0% (1 / 10) | Drifted cases returned `within_scope` (case `D-01`). |
| Escaped changes | 0.0% (0 / 9) | No post-merge amendment or follow-up found for merged `within_scope` cases during the recorded window. |
| Reviewer cost | $0.42 median; $0.31–$0.58 range per verdict | Reviewer token/API and linked reviewer-run infrastructure cost. |
| Human time | 3 minutes median active adjudication; 18 minutes median verdict-to-resolution | Active adjudication is separate from elapsed resolution time. |
| Rework | 10.0% (3 / 30) | Cases with `fix_pr` decision or a second reviewed head. |
| Delivery time | 27.0 hours median | PR creation to merged/closed timestamp. |

## Baseline and promotion decision

The predeclared baseline is the prior 30 comparable feature PRs for the named project, stratified by changed-file band. It recorded a 26.0-hour median delivery time and 0.0% escaped changes. The observed delivery-time increase is 3.8%, within the 20% limit; escaped changes did not increase.

| Promotion rule | Outcome |
| --- | --- |
| At least 30 adjudicated cases, at least 10 in every stratum | Met (30; 10/10/10) |
| Zero missed intentionally drifted cases | **Not met** (1 missed) |
| False-alarm rate at or below 10% | Met (10.0%) |
| No increase in escaped-change rate | Met (0.0% vs. 0.0%) |
| Median delivery time no worse than 20% above baseline | Met (3.8% above baseline) |
| Cost and human-time observations explicitly accepted | Accepted for shadow continuation only; no enforcement approval |

**Promotion-rule outcome: not promoted.** The project remains shadow-only. Corrective action: revise the reviewer prompt’s materiality-evidence section against `D-01`, then repeat a blinded, independently adjudicated drift stratum before reconsidering enforcement. Do not enable the scanner blocker, Inbox escalation, amendment flow, or `VerifyAtMerge` as part of this corrective work.
