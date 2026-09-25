---
parent: PAID
prefix: REVIEW-VERIFY
---

# Low-Level Design: Independent Verification of Paid PR Review Findings

> Companion to the high-level design (`docs/high-level-design.md`) and to the
> review-goal prompt segment (`docs/intent/review-pull-request/`). Defines the
> Find → Verify → Synthesize review pipeline piloted for the `paid_agent`
> review method (#3898).

## Purpose

Today one containerized review run both *identifies* findings and *posts* the
GitHub review. `Activities::CompleteReviewGoalActivity` verifies that a review
was posted, not whether its claims are sound. This segment introduces a staged
alternative in the control plane: a candidate-finding LLM session, an
independent verification session per candidate, and a synthesis stage that
produces exactly one tracked review containing only verified findings. The
pilot's purpose is to measure whether independent verification reduces
unsupported comments enough to justify its token cost and latency.

The pipeline is opt-in per project via
`review_settings.methods.paid_agent.independent_verification: true` and
defaults to off. When enabled, a review-goal run skips container provisioning
entirely and executes `Activities::RunVerifiedReviewActivity` instead of
`Activities::RunAgentActivity`. When disabled, the existing containerized
reviewer runs unchanged.

All LLM calls go through `agent_harness` (`AgentHarness.send_message`,
`tools: :none`) — never direct provider HTTP calls.

## Stage 1 — Find (`Reviews::Verification::FindCandidates`)

Fetches the PR metadata, the PR title/body (untrusted data), and the changed
files with patches from the GitHub API (bounded: max 100 files, max 3,000
characters of patch per file). A single LLM session returns candidate findings
as JSON. Every candidate MUST carry:

- **location** — `path` (a changed file) and `line` (right-side line in the
  new version),
- **summary** — one-sentence statement of the problem,
- **triggering_condition** — the input/state that triggers it,
- **failure_scenario** — the resulting incorrect behavior or concrete cost.

Mechanical validation drops candidates that reference unknown paths, missing
fields, or non-positive lines, and caps the set (max 15). A finder failure
(invalid JSON, harness error) aborts the run — it must not degrade into a
clean review.

## Stage 2 — Verify (`Reviews::Verification::VerifyCandidates`)

For each candidate, a *separate* model session receives: the candidate, the
patch hunk of its file, and a window of the file's actual content fetched at
the pinned head SHA. It returns:

- `verdict` — `confirmed`, `plausible`, or `refuted`,
- `evidence` — what the inspected code shows,
- `claim_key` — a short, stable, kebab-case identifier of the underlying
  claim (used for deduplication),
- optional `corrected_location` when the triggering line is nearby but the
  candidate cited the wrong one.

Any verdict outside the enum, or any harness/parse failure, aborts the run.
Verifier failure can never become a clean review because posting happens
strictly after every candidate has a recorded verdict.

## Publication policy (deliberate)

- **confirmed** → eligible for inline comments.
- **plausible** → withheld. Plausible is *not* equated with confirmed: the
  pilot exists to reduce unsupported comments, so plausible candidates are not
  published as comments and their content is not posted; the review body
  states only the *count* of withheld plausible observations.
- **refuted** → never published. This is enforced mechanically: synthesis only
  ever receives confirmed candidates, and every posted comment must cite
  confirmed candidate ids.

This policy is recorded here as the pilot's deliberate choice and revisited in
`pilot-measurement.md` once acceptance data exists.

## Deduplication and synthesis (`Reviews::Verification::SynthesizeReview`)

Confirmed candidates are grouped mechanically by `(path, claim_key)` — the
semantic identity of the claim is delegated to the verifier (ZFC); the
grouping itself is code. One LLM synthesis call receives the confirmed groups
and returns the review body plus one comment body per group, each citing its
`source_candidate_ids`. Post-synthesis mechanical guards:

- a comment citing anything other than confirmed candidates is dropped,
- a comment whose `(path, line)` is not a valid changed line of the pinned
  head is dropped; its finding moves into the review body as an unanchored
  bullet (the information survives, the bogus anchor does not),
- comments are capped at the number of confirmed groups (nothing invented).

Duplicate claims therefore yield exactly one comment: they share a group.

## Head SHA pinning

The pipeline pins the PR head SHA when it fetches the diff. File content for
verification is fetched at that SHA. Final comment anchors are validated
against the changed-line ranges parsed from that head's patches
(`Reviews::Verification::ChangedLines`). Immediately before posting, the head
is re-fetched:

- unchanged → post, with `commit_id` = pinned SHA so GitHub itself anchors the
  comments to that commit;
- changed → restart the whole pipeline once against the new head (never post
  stale line comments);
- changed again → fail the run (`ReviewHeadMoved`, non-retryable). The
  existing `review_goal_retry` machinery re-queues the review; no review is
  posted against a head the pipeline never examined.

## Posting (`Reviews::Verification::PostTrackedReview`)

Exactly one review per successful run, posted under the
`paid-code-reviewer[bot]` identity with the same tracking semantics the
container proxy produces:

- the review-bot installation token is used (`Github::ReviewBotInstallationToken`),
- the body is prefixed with `Github::ReviewMarker::PAID_REVIEW_MARKER` and the
  `## Code Review` header (shared constant with
  `Api::GithubProxyController#maybe_prepend_review_header`),
- the run's `review_posted_at` / `review_url` are updated on success — the
  same fields `Api::GithubProxyController#track_review_creation` writes — so
  `CompleteReviewGoalActivity` reconciliation works unchanged,
- posting is idempotent per run: if `review_posted_at` is already set, the
  poster returns the recorded review instead of posting again,
- the event is always `COMMENT`; `REQUEST_CHANGES`/`APPROVE` are never used.

A verified empty set (all candidates refuted, or no candidates found) posts
the existing clean-review contract: body containing the exact phrase
`Generated no new comments.` and the exact marker
`<!-- paid-review-clean -->` (`Activities::ScanPaidPrsActivity` constants), so
the review loop terminates exactly as it does today.

## Metrics

`Reviews::Verification::Pipeline` accumulates and the activity records, into
the `verified_review` phase metadata, a system agent-run log entry, and a
structured log line: candidate count; verdict counts (confirmed / plausible /
refuted); dedup group count; posted comment count; unanchored findings moved
to the body; outcome (`posted_findings`, `posted_unanchored`, `posted_clean`,
`already_posted`, `failed`); per-stage and total latency; LLM call counts;
model(s); token input/output totals and cost cents (via `TokenUsageTracker`).
`posted_unanchored` distinguishes "had confirmed findings, but every inline
comment was demoted to a body bullet by the anchor guard" from
`posted_clean` ("no findings produced"), so pilot metrics can group the two
cases separately. Per-stage latency is cumulative across attempts: when the
head-move retry path runs the pipeline a second time, the discarded
attempt's stage time is preserved — the run's real cost includes it.
No repository content — no file paths, diffs, summaries, or comment bodies —
is written to logs or phase metadata.

## Specialist-finder evaluation and second sweep

The generic finder is the baseline. A specialist finder is an additional,
focused candidate-generation session; it is not an additional publisher. The
first roles considered are **removed safeguards** (identify a deleted or
bypassed invariant and its concrete consequence) and **caller compatibility**
(identify an incompatible changed contract and a reachable caller). A second
sweep means one generic candidate-generation session after the baseline finder,
not a fan-out of reviewers.

Before either option can ship, run the paired evaluation recorded in
`pilot-measurement.md`. Each corpus PR is reviewed at the same pinned head by
the baseline pipeline and by exactly one variant: removed-safeguards finder,
caller-compatibility finder, or one second generic sweep. Both arms use the
same model configuration, changed-file/patch bounds, verification stage,
deduplication, publication policy, and exactly-one-tracked-review contract.
The variant's candidates are merged with baseline candidates before the
existing verifier; only confirmed, deduplicated findings can reach the single
posted review.

The evaluation is deliberately staged rather than enabled by a PR's text or
labels. Its corpus is stratified into clean PRs, seeded defects, and historical
PRs with an independently established author or defect outcome. It reports
incremental valid findings, false or duplicate findings, missed known defects,
wall time, and token cost by changed-file band and `review_depth_snapshot`.
The pre-registered decision rule and current result are in
`pilot-measurement.md`.

**Current decision:** do not ship specialist finders or a second sweep. There
is no live paired corpus result yet, so there is no evidence that the extra
candidate-generation call improves confirmed-findings recall enough to justify
its cost. `thorough` continues to express investigation scope to the existing
reviewer; it does not authorize fan-out. If a future result satisfies the
decision rule, the first implementation may be limited to one selected role
or one second sweep, only for the evaluated `thorough` cohort, with at most two
finder calls and the existing cap of 15 combined candidates before verification.
All findings remain independently verified before the one tracked review is
posted.

## Workflow routing

`Activities::ResolveReviewPipelineActivity` decides (per run, in an activity
so the workflow stays query-free) whether a review goal uses the verified
pipeline. `Workflows::AgentExecutionWorkflow` branches on its result behind
the Temporal patch `review-independent-verification-v1`, runs
`RunVerifiedReviewActivity` (no container), then the existing
`CompleteReviewGoalActivity`. Failure of the pipeline activity fails the run
through the normal workflow failure path, preserving the
`review_goal_retry` loop.

## Ownership and neighbors

- Prompt content for the containerized reviewer: `docs/intent/review-pull-request/`.
- Review loop machinery (scan, retry, escalation): PR lifecycle segments.
- This segment owns only the staged verification pipeline and its pilot flag.
