# RDR-067 Shadow Evaluation Aggregate Worksheet — 2026-10-09 (Invalidated)

<!-- @spec INTENT-CONFORMANCE-ROLLOUT-002 @spec INTENT-CONFORMANCE-ROLLOUT-003 -->

This worksheet is invalidated and is retained only as an audit trail for the
attempted evaluation. Its [corpus manifest](shadow-evaluation-manifest-2026-10-09.yml)
cannot be used as the case-level source of truth: the recorded design revision
postdates the adjudications, and the strata were assigned from contiguous
history blocks rather than independently content-adjudicating each case.

Consequently, all corpus counts, rates, costs, baselines, and promotion results
previously reported in this worksheet are withdrawn. A replacement evaluation
must freeze only identities available before adjudication and independently
construct or content-adjudicate at least ten accepted, intentionally drifted,
and uncertain cases.

## Superseded snapshot

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

## Required replacement evaluation

Keep `intent_conformance_shadow_review` as the only enabled RDR-067 flag.
Before another promotion review, construct or content-adjudicate every case
against an approved design revision that predates both adjudications, then
repeat blinded adjudication with a new frozen corpus. Do not derive stratum
labels from commit recency or report these invalidated metrics as a baseline.
Do not enable enforcement, scanner blockers, Inbox escalation, amendments, or
`VerifyAtMerge` from this result.
