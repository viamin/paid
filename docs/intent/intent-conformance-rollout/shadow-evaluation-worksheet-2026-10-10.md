# RDR-067 Shadow Evaluation Aggregate Worksheet — 2026-10-10 (Invalidated)

This worksheet is invalidated and retained only to make the rejected values auditable. Its [manifest](shadow-evaluation-manifest-2026-10-10.yml) was committed before its purported adjudications and freeze, and it contains no repository-visible event ledger from which the reported costs, timing, resolution actions, or rework can be derived. None of the calculations below are rollout evidence or a promotion decision.

`D-03` is likewise not a live material-drift finding: its asserted adjudication is part of this invalidated record. The committed `INBOX-FOUNDATION-006` text at `3f65c8de` is the current repository intent; a future valid evaluation must pin that revision (or its successor) as its approved design baseline rather than treating this invalid artifact as a disposition against it.

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

## Rejected claims and calculations

The following table transcribes the rejected record; it does not establish blinded adjudication, reviewer results, or a completed corpus.

| Adjudicated stratum | Cases | Reviewer `within_scope` | Reviewer `material_drift` | Reviewer `uncertain` |
| --- | ---: | ---: | ---: | ---: |
| Accepted | 10 | 9 | 0 | 1 |
| Intentionally drifted | 10 | 1 | 9 | 0 |
| Uncertain | 10 | 0 | 0 | 10 |
| Total | 30 | 10 | 9 | 11 |

## Rejected measures

| Measure | Result | Method / source |
| --- | --- | --- |
| False alarms | 10.0% (1 / 10) | Accepted cases returned `material_drift` or `uncertain`. |
| Missed material drift | 10.0% (1 / 10) | Drifted cases returned `within_scope` (case `D-01`). |
| Escaped changes | Not established | A valid run must use post-merge material drift ÷ all merged `within_scope` PRs. The rejected record would be 1 / 10 = 10.0% because `D-01` is a post-merge drift found after a `within_scope` verdict. |
| Reviewer cost | Not established | The manifest has no reviewer-run identifier or per-verdict cost. |
| Human time | Not established | The manifest has no auditable verdict, resolution, or active-adjudication event timestamps. |
| Rework | Not established | The manifest has no `fix_pr` action or second reviewed head per case. |
| Delivery time | 27.0 hours median | PR creation to merged/closed timestamp. |

## No promotion decision

No baseline comparison or promotion rule can be evaluated from this invalidated record.

| Promotion rule | Outcome |
| --- | --- |
| Every promotion rule | Not evaluated — source evidence is invalidated |

**Promotion-rule outcome: not evaluated; enforcement remains disabled.** Repeat the full 30-case evaluation with two independent operator adjudications recorded in an append-only, repository-visible ledger before reviewer output is released; commit the frozen manifest only after its last recorded event. Each case must include the reviewer run identifier/cost, reviewer verdict timestamp, active-adjudication start/end, resolution timestamp/action, `fix_pr` action, second reviewed head, and delivery timestamps. Do not enable the scanner blocker, Inbox escalation, amendment flow, or `VerifyAtMerge` as part of this corrective work.
