# EARS Specs: Independent Verification of Paid PR Review Findings

> Testable claims for the Find → Verify → Synthesize review pipeline (#3898).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r REVIEW-VERIFY-001`).

## Pilot gating

- [x] **REVIEW-VERIFY-001** — When a project's effective
  `review_settings.methods.paid_agent` has
  `independent_verification == true` and `enabled == true`, a review-goal run
  for that project SHALL execute the staged verification pipeline
  (`Activities::ResolveReviewPipelineActivity` returns `pipeline:
  "verified"`, and `Workflows::AgentExecutionWorkflow` runs
  `RunVerifiedReviewActivity` without provisioning a container). The flag
  SHALL default to false, and setting it while `paid_agent` is disabled
  SHALL be a project validation error.
  *Code:* `app/models/project.rb`,
  `app/temporal/activities/resolve_review_pipeline_activity.rb`,
  `app/temporal/workflows/agent_execution_workflow.rb`.
  *Tests:* `spec/models/project_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_spec.rb`.

## Candidate stage

- [x] **REVIEW-VERIFY-002** — The finder stage SHALL return, for every
  candidate finding, a location (changed-file path and line), a summary, a
  triggering condition, and a failure scenario or concrete cost. Candidates
  that reference a path not changed in the PR, omit a required field, or
  carry a non-positive line SHALL be dropped before verification, and the
  candidate set SHALL be capped. All finder LLM calls SHALL go through
  `AgentHarness`.
  *Code:* `app/services/reviews/verification/find_candidates.rb`.
  *Tests:* `spec/services/reviews/verification/find_candidates_spec.rb`.

## Verification stage

- [x] **REVIEW-VERIFY-003** — Each candidate SHALL be inspected by a model
  session separate from the finder session, given the candidate plus the
  relevant code (file content window at the pinned head SHA and the file's
  patch), and SHALL yield exactly one verdict — `confirmed`, `plausible`, or
  `refuted` — with evidence and a stable `claim_key`. An unparseable or
  out-of-enum verdict, or any verifier LLM failure, SHALL abort the run
  without posting any review.
  *Code:* `app/services/reviews/verification/verify_candidates.rb`.
  *Tests:* `spec/services/reviews/verification/verify_candidates_spec.rb`.

- [x] **REVIEW-VERIFY-004** — Publication policy SHALL be: only `confirmed`
  candidates are eligible for inline comments; `plausible` candidates SHALL
  be withheld (the review body MAY state only the count of withheld
  plausible observations, never their content); `refuted` candidates SHALL
  never appear in the posted review. The refuted exclusion SHALL be enforced
  mechanically — synthesis receives only confirmed candidates, and a posted
  comment citing any non-confirmed candidate SHALL be dropped.
  *Code:* `app/services/reviews/verification/pipeline.rb`,
  `app/services/reviews/verification/synthesize_review.rb`.
  *Tests:* `spec/services/reviews/verification/synthesize_review_spec.rb`,
  `spec/services/reviews/verification/pipeline_spec.rb`.

## Deduplication and synthesis

- [x] **REVIEW-VERIFY-005** — Confirmed candidates SHALL be deduplicated by
  `(path, claim_key)` before synthesis, and the final review SHALL contain at
  most one inline comment per deduplication group, so duplicate claims yield
  one comment. Synthesis output SHALL be capped at the number of confirmed
  groups.
  *Code:* `app/services/reviews/verification/pipeline.rb`,
  `app/services/reviews/verification/synthesize_review.rb`.
  *Tests:* `spec/services/reviews/verification/pipeline_spec.rb`.

## Posting contract

- [x] **REVIEW-VERIFY-006** — Each successful pipeline run SHALL submit
  exactly one GitHub review through the tracked path: the
  `paid-code-reviewer[bot]` installation-token identity, the
  `Github::ReviewMarker::PAID_REVIEW_MARKER` body marker, event `COMMENT`,
  and the run's `review_posted_at` / `review_url` updated on success. A run
  whose review was already posted SHALL NOT post a second review. A verified
  empty set (zero candidates found, or all candidates refuted) SHALL post the
  existing clean-review body containing both the exact phrase `Generated no
  new comments.` and the `<!-- paid-review-clean -->` marker.
  *Code:* `app/services/reviews/verification/post_tracked_review.rb`,
  `app/services/reviews/verification/pipeline.rb`.
  *Tests:* `spec/services/reviews/verification/post_tracked_review_spec.rb`,
  `spec/services/reviews/verification/pipeline_spec.rb`.

## Head SHA pinning

- [x] **REVIEW-VERIFY-007** — The pipeline SHALL pin the PR head SHA before
  finding candidates, fetch verification code context at that SHA, and
  re-check the head immediately before posting. If the head changed since
  pinning, the pipeline SHALL restart once against the new head instead of
  publishing stale line comments; if the head changes again, the run SHALL
  fail without posting. The posted review payload SHALL carry `commit_id` =
  the pinned SHA.
  *Code:* `app/services/reviews/verification/pipeline.rb`,
  `app/services/reviews/verification/post_tracked_review.rb`.
  *Tests:* `spec/services/reviews/verification/pipeline_spec.rb`.

- [x] **REVIEW-VERIFY-008** — Every inline comment SHALL reference a valid
  changed line (right side) of the pinned head for a file changed in the PR.
  A synthesized comment with an invalid anchor SHALL be dropped and its
  finding surfaced in the review body as an unanchored bullet instead.
  *Code:* `app/services/reviews/verification/changed_lines.rb`,
  `app/services/reviews/verification/synthesize_review.rb`.
  *Tests:* `spec/services/reviews/verification/changed_lines_spec.rb`,
  `spec/services/reviews/verification/synthesize_review_spec.rb`.

## Metrics

- [x] **REVIEW-VERIFY-009** — Each run SHALL record candidate and verdict
  counts, dedup group count, posted comment count, outcome, per-stage and
  total latency, LLM call counts, model(s), and token usage with cost — via
  phase metadata, an agent-run system log, and a structured log line. Logs
  and phase metadata SHALL NOT contain repository content (paths, patches,
  summaries, or comment bodies).
  *Code:* `app/services/reviews/verification/pipeline.rb`,
  `app/temporal/activities/run_verified_review_activity.rb`.
  *Tests:* `spec/services/reviews/verification/pipeline_spec.rb`,
  `spec/temporal/activities/run_verified_review_activity_spec.rb`.

## Pilot measurement

- [x] **REVIEW-VERIFY-010** — The pilot SHALL be compared against the
  containerized reviewer using author acceptance/correction of posted
  comments, later missed defects, wall-clock time, and token cost, and the
  comparison method and default-use recommendation SHALL be documented in
  `docs/intent/review-verification/pilot-measurement.md`.
  *Docs:* `docs/intent/review-verification/pilot-measurement.md`,
  `docs/intent/review-verification/review-verification-design.md`.
  *Tests:* segment registered in `docs/arrows/index.yaml`;
  `bin/coherence-check.mjs` passes with this segment.
