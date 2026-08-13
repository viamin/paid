# EARS Specs: Queue Priority Tiers

> Testable claims for work-category-aware dequeue ordering of queued runs
> (RDR-047). Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r QUEUE-TIER-001`).

## Category-first tier structure

- [x] **QUEUE-TIER-001** — The system SHALL rank queued runs by a 9-tier
  category-first scheme in which manual runs pre-empt unconditionally, then
  PR-continuation runs (`source_pull_request_number` present) are ranked by
  label (P1 > P2 > P3 > none) ahead of all fresh-issue runs ranked by the
  same label order, so category is the primary discriminator and label the
  secondary one within each category.
  *Code:* `AgentRun::QUEUE_PRIORITIES`, `AgentRun::QUEUE_PRIORITY_CASE_SQL`,
  `AgentRun::LABEL_RANK_CASE_SQL`.
  *Test:* `spec/models/agent_run_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`.

- [x] **QUEUE-TIER-002** — The system SHALL resolve a run's tier in Ruby
  (`queue_priority_tier`) to match the SQL `CASE` exactly: `manual` when
  manual, otherwise the run's category combined with its resolved label
  tier, yielding one of `pr_p1`/`pr_p2`/`pr_p3`/`pr_continue` or
  `issue_p1`/`issue_p2`/`issue_p3`/`auto_pick`.
  *Code:* `AgentRun#queue_priority_tier`, `AgentRun#label_priority_tier`,
  `AgentRun#existing_pr?`.
  *Test:* `spec/models/agent_run_spec.rb`.

## Cross-category tie-break (the motivating case)

- [x] **QUEUE-TIER-003** — When a P2-labeled PR-continuation run and a
  P1-labeled fresh-issue run are both queued, the PR-continuation run SHALL
  dequeue first, because a ready PR follow-up outranks a not-yet-started
  fresh issue regardless of label rank across categories.
  *Code:* `AgentRun::QUEUE_PRIORITY_CASE_SQL`,
  `AgentRun::QUEUE_ORDER`.
  *Test:* `spec/models/agent_run_spec.rb` (worked-example ordering spec),
  `spec/jobs/process_run_queue_job_spec.rb`.

## Badge rendering parity

- [x] **QUEUE-TIER-004** — The system SHALL map every queue priority tier to
  a badge label and a non-fallback badge style, so PR-continuation tiers
  render as "PR · P1/P2/P3"/"Auto-continue" and fresh-issue tiers render as
  "P1/P2/P3"/"Auto-pick" without any tier falling back to the unknown style.
  *Code:* `AgentRun#queue_priority_label`, `ApplicationHelper::AGENT_RUN_PRIORITY_STYLES`.
  *Test:* `spec/helpers/application_helper_agent_run_priority_spec.rb`.

## Fair-stride and manual pre-emption preserved

- [x] **QUEUE-TIER-005** — The category-first tier SHALL remain the third
  sort key in `QUEUE_ORDER`, after the cross-project and cross-user
  in-flight-count fair-stride keys, so a single project's deep high-priority
  backlog cannot starve other projects; and `trigger_type = 'manual'` SHALL
  remain tier 0 unconditionally, independent of category or label.
  *Code:* `AgentRun::QUEUE_ORDER`, `AgentRun::PROJECT_ACTIVE_COUNT_SQL`,
  `AgentRun::USER_ACTIVE_COUNT_SQL`, `AgentRun::IN_PROGRESS_SQL`.
  *Test:* `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/services/dashboard/queue_preview_spec.rb`.

## Workability trusted upstream

- [x] **QUEUE-TIER-006** — The ordering layer SHALL NOT re-check whether a
  queued PR-continuation run is workable, because CI-pending PRs never
  queue a run, paused PRs are excluded at the scan source
  (`Issue.auto_continue_active`), and `QueueAgentRunActivity#find_existing_run`
  row-locks so an active PR cannot double-queue.
  *Code:* `ScanPaidPrsActivity` (scan gating), `Issue.auto_continue_active`,
  `QueueAgentRunActivity#find_existing_run`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
