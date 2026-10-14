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

- [x] **TDD-PR-007** — When a `test_writing` run publishes a new commit to a
  TDD pull request, Paid SHALL replace any preceding approval or changes
  requested verdict with `paid-tests-ready-for-review`, both for GitHub-label
  and local-control projects. A no-output run or a failed/partial remote label
  transition SHALL NOT claim a new local revision; an older rejection SHALL
  not trigger another test-writing run after a newer revision exists.
  *Code:* `app/services/tdd/publish_test_revision.rb`,
  `app/temporal/activities/complete_existing_pr_run_activity.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Test:* `spec/services/tdd/publish_test_revision_spec.rb`,
  `spec/temporal/activities/complete_existing_pr_run_activity_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
