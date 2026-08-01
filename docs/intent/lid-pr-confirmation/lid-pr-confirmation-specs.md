# EARS Specs: LID Planning PR Confirmation

> Testable claims for the Planning PR confirmation loop. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **LID-PR-CONFIRM-001** — When a Planning PR branch's entire diff is
  docs-only (LID docs and/or agent instruction files) and contains `[inferred]`
  markers or `## Open Questions` items, the system SHALL append a "Confirm
  These Inferred Decisions" checklist to the PR body derived from those branch
  contents. A PR whose diff touches any non-doc file SHALL NOT receive the
  checklist, so an ordinary implementation PR that happens to also touch LID
  docs is never misclassified as a Planning PR.
  *Tests:* `spec/services/lid/build_inference_checklist_spec.rb`,
  `spec/temporal/activities/create_pull_request_activity_spec.rb`.
  *Code:* `app/services/lid/build_inference_checklist.rb`,
  `app/temporal/activities/create_pull_request_activity.rb#append_inference_checklist`.

- [x] **LID-PR-CONFIRM-002** — When a docs-only Planning PR receives review
  feedback, the follow-up prompt SHALL instruct the agent to replace corrected
  `[inferred]` markers with authored rationale and cascade the correction into
  related LLD/EARS text on the same PR branch.
  *Tests:* `spec/services/prompts/build_for_pr_spec.rb`,
  `spec/temporal/activities/prepare_pr_prompt_activity_lid_planning_pr_review_flow_spec.rb`.
  *Code:* `app/services/prompts/build_for_pr.rb#planning_pr_intent_confirmation_section`.

- [x] **LID-PR-CONFIRM-003** — When a docs-only Planning PR has unresolved
  review threads but no reviewer has submitted a `CHANGES_REQUESTED` review,
  the PR scanner SHALL NOT enqueue a follow-up `review_feedback` run for those
  threads (comment-only feedback stays deferable). A `CHANGES_REQUESTED`
  review SHALL still enqueue the follow-up run via the existing
  `changes_requested` trigger.
  *Tests:* `spec/temporal/activities/prepare_pr_prompt_activity_lid_planning_pr_review_flow_spec.rb`.
  *Code:* `app/temporal/activities/scan_paid_prs_activity.rb#human_review_thread_triggers`,
  `app/temporal/activities/scan_paid_prs_activity.rb#planning_pr?`.
