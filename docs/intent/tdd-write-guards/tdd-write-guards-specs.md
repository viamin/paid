# EARS Specs: Run-Scoped TDD Write Guards (RDR-056)

> Testable claims for per-phase file-change enforcement on TDD-governed agent
> runs. Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r TDD-GUARD-001`).

- [x] **TDD-GUARD-001** — An `AgentRun` SHALL persist a `tdd_phase` string
  column restricted to `test_writing`, `test_fixing`, or `refactor`, and
  SHALL allow `nil` for runs that are not TDD-governed (e.g. `tdd_mode: off`
  projects or non-TDD goals).
  *Code:* `app/models/agent_run.rb`,
  `db/migrate/20260822000026_add_tdd_phase_to_agent_runs.rb`.
  *Test:* `spec/models/agent_run_spec.rb`.

- [x] **TDD-GUARD-002** — `AgentRun` SHALL expose `tdd_test_writing_phase?`,
  `tdd_test_fixing_phase?`, `tdd_refactor_phase?`, and `tdd_governed?`
  predicate methods so callers can branch on phase without repeating string
  comparisons.
  *Code:* `app/models/agent_run.rb`.
  *Test:* `spec/models/agent_run_spec.rb`.

- [x] **TDD-GUARD-003** — `Tdd::WriteGuard` SHALL reject a `test_writing`
  run's changed files if any fall outside the test-path pattern
  (`spec/`, `test/`, `.ephemeral-tests/`) or the LID doc allowlist (`docs/`,
  `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`), reporting the
  offending implementation files.
  *Code:* `app/services/tdd/write_guard.rb`.
  *Test:* `spec/services/tdd/write_guard_spec.rb`.

- [x] **TDD-GUARD-004** — `Tdd::WriteGuard` SHALL reject a `test_fixing`
  run's changed files if any fall inside the test-path pattern, UNLESS
  `agent_run.tdd_returned_to_test_review?` is true, in which case test
  changes are allowed for the remainder of the run.
  *Code:* `app/services/tdd/write_guard.rb`.
  *Test:* `spec/services/tdd/write_guard_spec.rb`.

- [x] **TDD-GUARD-005** — `Tdd::WriteGuard` SHALL reject a `refactor` run's
  changed files if any fall inside the test-path pattern, with no exception
  — refactor runs may never edit the frozen, approved test suite.
  *Code:* `app/services/tdd/write_guard.rb`.
  *Test:* `spec/services/tdd/write_guard_spec.rb`.

- [x] **TDD-GUARD-006** — `CreatePullRequestActivity` SHALL run
  `Tdd::WriteGuard` against the run's actual changed files (via the same
  GitHub-compare-API fetch used by `lid_planning`/`create_feature` guards)
  for every `tdd_governed?` run, regardless of goal, and SHALL abort the run
  with a descriptive error naming the forbidden files when the guard reports
  a violation.
  *Code:* `app/temporal/activities/create_pull_request_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.

- [x] **TDD-GUARD-007** — `Tdd::ReturnToTestReview` SHALL, for a
  `test_fixing`-phase run with a resolvable PR number and GitHub client,
  remove the `paid-tests-approved` label, add the
  `paid-tests-ready-for-review` label (both remotely and on the locally
  synced `Issue#labels`), and set `agent_run.tdd_returned_to_test_review =
  true` in the same call — so the flag is never set without the PR's labels
  reflecting the reset.
  *Code:* `app/services/tdd/return_to_test_review.rb`.
  *Test:* `spec/services/tdd/return_to_test_review_spec.rb`.

- [x] **TDD-GUARD-008** — `Tdd::ReturnToTestReview` SHALL fail without
  raising — returning a result with `success?: false` and a reason — when
  the run is not in `test_fixing` phase, when no PR number is resolvable, or
  when the project has no GitHub client; remote label-sync errors
  (`GithubClient::Error`, `Faraday::Error`) SHALL be caught and logged as a
  warning rather than aborting the reset, since the local flag update is
  what write-guard enforcement actually depends on.
  *Code:* `app/services/tdd/return_to_test_review.rb`.
  *Test:* `spec/services/tdd/return_to_test_review_spec.rb`.

- [x] **TDD-GUARD-009** — `Containers::QualityHooks#install_quality_hooks`
  SHALL suppress the mutation pre-commit command when the run is in
  `test_writing` phase, regardless of project mutation configuration, since
  there is no implementation yet to mutate. `test_fixing` and `refactor`
  phases SHALL retain the normal mutation-command resolution.
  *Code:* `app/services/containers/quality_hooks.rb`.
  *Test:* `spec/services/containers/quality_hooks_spec.rb`.
