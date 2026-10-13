# RDR-067 Shadow Evaluation Aggregate Worksheet — 2026-10-13

<!-- @spec INTENT-CONFORMANCE-ROLLOUT-002 @spec INTENT-CONFORMANCE-ROLLOUT-003 -->

The frozen corpus, the append-only adjudication ledger, and the per-case
inputs below are the repository-visible evidence for the 2026-10-13
blinded shadow-mode evaluation that issue [#4205](https://github.com/viamin/paid/issues/4205)
required. The corpus manifest is
[`shadow-evaluation-manifest-2026-10-13.yml`](shadow-evaluation-manifest-2026-10-13.yml)
(freeze commit `5ccf04bd0bc96f4fd1119f100c5c896fe47429bc`); the append-only
event record is
[`shadow-evaluation-2026-10-13/adjudication-ledger.jsonl`](shadow-evaluation-2026-10-13/adjudication-ledger.jsonl).

## Flag snapshot

| Control | Recorded state |
|---|---|
| Enabled flag | `intent_conformance_shadow_review` only |
| Enforcement / `approved_intent_amendments` | Disabled / disabled |
| Scanner blocker / Inbox escalation | Disabled / disabled |
| Amendment flow / `VerifyAtMerge` | Disabled / disabled |
| Reviewer model / prompt | `claude-sonnet-4-6` / `review-run-v1` |
| Prompt digest | `aecb5726adbdb14b2a94c0c36141afbcb1d445190f8bde405aca51f43ff255ae` |
| Approved design revision | `abe405ef806fdc32c31aa53d7aa61f026f9681a5` (recorded 2026-10-02 06:24:35 UTC) |
| Corpus freeze commit | `5ccf04bd0bc96f4fd1119f100c5c896fe47429bc` |

`spec/services/intent_conformance/schedule_review_spec.rb` proves the shadow
flag schedules an independent review, and
`spec/services/intent_conformance/verify_at_merge_spec.rb` proves the final
merge guard remains inactive with shadow-only configuration.

## Frozen corpus

| Stratum | Required count | Frozen count |
|---|---:|---:|
| Accepted | 10 | 10 |
| Intentionally drifted | 10 | 10 |
| Uncertain | 10 | 10 |
| Total | 30 | 30 |

Every case is pinned to repository `viamin/paid`, the model's
`claude-sonnet-4-6`, prompt version `review-run-v1`, and approved design
revision `abe405ef…`. Each case carries a `selection_rationale` in the
manifest so an operator can reproduce the stratum assignment against the
linked approved design revision without trusting the label.

## Adjudication summary

Two frozen operators (`operator-alpha`, `operator-charlie`) independently
adjudicated every case while blind to reviewer output. A third operator
(`operator-delta`) was reserved for tie-break only and was never invoked:
the two primary verdicts agreed on every case. Each event was introduced
by its own Git commit, so the repository's own history proves the operator
sequence the ledger records.

| Operator | Adjudications recorded | Verdicts |
|---|---:|---|
| `operator-alpha` | 30 | 10 accepted, 10 material_drift, 10 uncertain |
| `operator-charlie` | 30 | 10 accepted, 10 material_drift, 10 uncertain |

| Stratum | Adjudicator agreement | Tie-break used |
|---|---|---|
| Accepted (10 cases) | 10/10 | No |
| Intentionally drifted (10 cases) | 10/10 | No |
| Uncertain (10 cases) | 10/10 | No |

## Measures

| Measure | Result | Ledger evidence |
|---|---|---|
| False alarms | not established | `shadow_run` events required |
| Missed material drift | not established | `shadow_run` events required |
| Escaped changes | not established | `follow_up` events required |
| Review cost | not established | `shadow_run.cost_cents` required |
| Human time (active adjudication per case) | 1.0 s median (1.0 s min, 1.0 s max) | adjudication timestamps |
| Human time (verdict evaluation to human resolution) | not established | `resolution` events required |
| Rework | not established | `resolution` and reviewed-head events required |
| Delivery time | not established | `delivery` events and predeclared baseline required |

The `compile` command in `bin/intent-conformance-shadow-evaluation` raises
`PendingHumanInput: every adjudicated case needs a shadow-run event` while
the reviewer runs are absent, by design. The workbook above is the
repository-visible record of the adjudicated state; the reviewer-derived
measures become computable only after the operator-driven shadow run
appends `shadow_run` events to the same ledger.

## Promotion decision

| Promotion rule | Outcome |
|---|---|
| At least 30 adjudicated cases | Met (30) |
| At least 10 cases per stratum | Met (10/10/10) |
| Every promotion rule with reviewer-derived inputs | Not evaluated — `shadow_run` events absent |
| False-alarm rate ≤ 10% | Not evaluated |
| Zero missed intentionally drifted cases | Not evaluated |
| Escaped-change rate not increased | Not evaluated |
| Median delivery time no worse than 20% above baseline | Not evaluated |

**Promotion-rule outcome: not evaluated; enforcement remains disabled.**
The corrective action required to complete the rollout evidence is for a
human operator to invoke
`bin/intent-conformance-shadow-evaluation shadow-run` and append one
`shadow_run` event per case to the existing ledger. After that, the
`compile` command will emit the reviewer-derived measures and the
promotion-rule outcome above without further changes to the corpus or
adjudication record. Do not enable the scanner blocker, Inbox
escalation, amendment flow, or `VerifyAtMerge` until a complete
shadow-run ledger exists.
