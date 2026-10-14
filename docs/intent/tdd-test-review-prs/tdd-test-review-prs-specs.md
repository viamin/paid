# EARS Specs: TDD Test-Review PRs (RDR-056)

> Testable claims for red-phase draft PR publication and PR-body review
> sections. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred.

- [x] **TDD-PR-001** — A `test_writing` run SHALL create or refresh the pull
  request review surface after pushing tests, and SHALL apply the
  `paid-tests-ready-for-review` label so the PR clearly waits at the red-phase
  test-review gate.
  *Code:* `app/temporal/activities/create_pull_request_activity.rb`,
  `app/temporal/activities/complete_existing_pr_run_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`,
  `spec/temporal/activities/complete_existing_pr_run_activity_spec.rb`.

- [x] **TDD-PR-002** — Any PR whose diff includes tests SHALL include a
  `## Test Outline` section in the PR body.
  *Code:* `app/services/pull_requests/review_surface.rb`.
  *Test:* `spec/services/pull_requests/review_surface_spec.rb`.

- [x] **TDD-PR-003** — For RSpec-style test files, the test outline SHALL
  render nested suite/context titles and example titles in documentation-style
  plain text, without test bodies or assertions.
  *Code:* `app/services/pull_requests/review_surface.rb`.
  *Test:* `spec/services/pull_requests/review_surface_spec.rb`.

- [x] **TDD-PR-004** — For non-RSpec test files, the test outline SHALL render
  the nearest structural hierarchy/title summary available from the file's test
  declarations.
  *Code:* `app/services/pull_requests/review_surface.rb`.
  *Test:* `spec/services/pull_requests/review_surface_spec.rb`.

- [x] **TDD-PR-005** — For LID-enabled projects, the PR body SHALL show both
  changed LID docs/spec evidence and the existing coherence-check reporting in
  the red-phase review surface before implementation begins.
  *Code:* `app/services/pull_requests/review_surface.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.

- [x] **TDD-PR-006** — In non-strict TDD mode, the scanner SHALL accept a
  `paid_agent` test-review verdict only when that review applies to the current
  test revision; older verdicts from before a newer test-writing or test-fixing
  push SHALL NOT re-apply `paid-tests-approved` or
  `paid-test-changes-requested`. The test-review run SHALL authenticate as the
  dedicated Paid reviewer and the scanner SHALL recognize that reviewer even
  when ordinary PR reviews are disabled. When no current verdict is available,
  the scanner SHALL honor the existing completed-review suppression and
  configured review-round and retry limits rather than enqueueing a review of
  identical tests indefinitely.
  *Code:* `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/controllers/api/github_proxy_controller.rb`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/requests/api/github_proxy_spec.rb`.

- [x] **TDD-PR-007** — When a current TDD test review rejects the proposed
  tests, the scanner SHALL queue a `test_writing` revision run only with a
  snapshot of the trusted review body and/or unresolved trusted review-thread
  comments that caused that rejection. The revision prompt SHALL identify the
  review provenance and require updating only the proposed tests and returning
  the PR to the test-review gate; it SHALL NOT treat implementation as complete.
  Untrusted comment bodies SHALL be excluded. If no current trusted feedback is
  available, or the latest test-writing run ended `no_changes` against the same
  feedback snapshot, the scanner SHALL escalate the PR for manual review rather
  than queueing another generic run.
  *Code:* `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/services/automation/strategies/auto_review.rb`,
  `app/temporal/activities/queue_agent_run_activity.rb`,
  `app/services/prompts/build_for_pr.rb`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/services/automation/strategies/auto_review_spec.rb`,
  `spec/services/prompts/build_for_pr_spec.rb`.
  When `draft_review_count` has reached a positive configured
  `max_draft_review_rounds`, it SHALL escalate rather than schedule another
  automatic test-revision run, whether the verdict comes from GitHub labels or
  Paid-local control state and including repeated no-change outcomes. A current
  actionable human review thread MAY proceed through the ordinary
  human-feedback path, and an approved test verdict SHALL still transition to
  implementation; neither exception SHALL permit repeated automated rejected
  test revisions beyond the cap. A zero limit SHALL remain disabled and an
  explicit operator restart SHALL retain its established counter-reset
  semantics.
