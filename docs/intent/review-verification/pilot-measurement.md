# Pilot Measurement: Independent Verification vs. Current Reviewer (#3898)

> How Paid will decide whether the staged Find → Verify → Synthesize pipeline
> (`review_settings.methods.paid_agent.independent_verification`) should
> become the default for the `paid_agent` reviewer. This document defines the
> comparison *method* now and records the decision once pilot data exists.

## Status

Pilot deployed behind a per-project opt-in flag; **not** default. No
conclusion yet — the sections below will be filled from pilot runs.

## Method

Run both reviewers on comparable PRs (same project, interleaved rounds) for
an evaluation window of at least 30 reviews per arm, then compare:

| Dimension | Source of truth |
|---|---|
| Author acceptance / correction | GitHub reactions and replies on posted inline comments: thumbs-up or applied suggestion = accepted; author rebuttal or "not an issue" reply = corrected. Tracked per review as accepted/corrected counts. |
| Later missed defects | Defects surfaced in a *later* round or post-merge (fix-up commits, follow-up issues) on lines the earlier review cleared. |
| Time | `AgentRunPhase` latencies: verified pipeline (`verified_review` phase) vs. container review runs (`run_agent` phase) for the same PR. |
| Token cost | `TokenUsageTracker` rows (`request_type: "agent"`, operations `verified_review.find` / `verified_review.verify` / `verified_review.synthesize`) vs. the container run's tracked usage. |

The pipeline additionally self-reports per-run counts (candidates,
confirmed/plausible/refuted, dedup groups, comments, unanchored findings,
latency, models, tokens, cost) in the `verified_review` phase metadata and the
`review_verification.completed` log line — none of which contain repository
content.

## Decision rule (agreed in advance)

Independent verification merits default use only if, on pilot data:

1. Unsupported-comment rate (corrected ÷ posted) drops materially (target:
   ≥ 50% relative reduction vs. the containerized reviewer),
2. the confirmed-finding recall does not collapse (later-missed-defect rate
   not worse than the current reviewer's), and
3. the added token cost and latency stay within budget (target: ≤ 2× the
   container reviewer's token cost per review; total pipeline wall clock
   within the `paid_agent` `timeout_minutes` budget, default 30).

If (1) holds but (3) fails, next step is batching verifier sessions (one call
for all candidates) before reconsidering the default — per-candidate
verification latency/cost is recorded precisely so this trade can be made
from data.

## Interim decision

Until the pilot data is in: `independent_verification` stays an opt-in pilot;
the containerized reviewer remains the default. Revisit this document after
the evaluation window closes.

## Specialist finder and second-sweep evaluation (#3900)

### Status and result

**Not run; do not ship.** The prerequisites now expose depth snapshots and the
verified baseline, but this repository has no approved paired PR corpus,
recorded ground truth, or live-review outcomes from which to derive a valid
effectiveness or cost result. This is an explicit result, not a zero-finding
result: the table below is intentionally blank rather than treating absent
measurements as clean reviews or free calls.

| Variant | Eligible PRs | Additional valid findings | False / duplicate findings | Missed known defects | Median wall time | Median token cost | Decision |
|---|---:|---:|---:|---:|---:|---:|---|
| Removed safeguards finder | — | — | — | — | — | — | Do not ship |
| Caller compatibility finder | — | — | — | — | — | — | Do not ship |
| One second generic sweep | — | — | — | — | — | — | Do not ship |

The generic verified finder remains the only evaluated candidate-generation
path. `thorough` remains an instruction-scope preset, not a trigger for more
agents. Re-open this decision only after the protocol below produces paired
measurements.

### Reproducible protocol

1. Build a frozen manifest of at least 30 PR heads, balanced across three
   strata: clean PRs (no independently established defect), seeded-defect PRs
   (a known injected removed-safeguard or caller-contract defect), and
   historical PRs (a later fix-up, follow-up issue, or author outcome establishes
   ground truth). Record repository, PR number, pinned head SHA, base SHA,
   stratum, known-defect identifiers, changed-file band (1–5, 6–20, 21+), and
   `review_depth_snapshot`. Keep the manifest and adjudication evidence private
   to the evaluation project; do not place repository content in run logs.
2. For every manifest entry, run the generic verified pipeline and one variant
   against the identical pinned head. Interleave arm order, hold model and
   prompt versions, file/patch limits, candidate cap, and timeout constant, and
   use the same verifier, deduplication, and publication policy. The variants
   are: one removed-safeguards finder, one caller-compatibility finder, or one
   second generic finder sweep. Evaluate one variant at a time; do not combine
   roles during this decision.
3. Retain the pipeline phase metadata, `review_verification.completed` log
   metadata, and token-usage rows for each arm. Adjudicators blind to arm label
   classify each confirmed finding as valid, false, or duplicate and map it to
   known defects. Count a known defect as missed only when its arm produced no
   valid confirmed finding for it. Use the existing tracked-review path for any
   publication, so each arm emits at most one final review.
4. Publish only aggregate results by stratum, changed-file band, and depth:
   incremental valid findings; false and duplicate findings; missed known
   defects; `verified_review` wall time; and input/output tokens plus cost
   cents. Report medians and ranges as well as totals, and retain failures and
   head-move restarts in time/cost totals.

### Pre-registered shipping rule

Ship no more than one role or one second sweep only when its paired result on
the `thorough` cohort has all of the following: a positive incremental count
of adjudicated valid findings; no worse missed-known-defect rate; no material
increase in false/duplicate rate; and median incremental token cost and wall
time within the project review budget. The result must be stable across at
least two corpus strata; a seeded-only win is insufficient.

If these criteria are met, ship it only for `thorough` review runs, with a
maximum of two finder calls total (baseline plus one variant) and 15 combined
candidates before existing per-candidate verification. Merge candidates before
verification, deduplicate confirmed findings, and post exactly one tracked
GitHub review. Otherwise retain the current decision: no specialist finder and
no second sweep. Limitations of this method are model nondeterminism, imperfect
historical ground truth, corpus selection bias, and the fact that a staged
evaluation may not represent future projects or models; record model versions,
rerun count, and exclusions with every result update.
