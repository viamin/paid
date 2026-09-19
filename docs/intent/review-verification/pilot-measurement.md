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
