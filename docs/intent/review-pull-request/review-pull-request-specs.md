# EARS Specs: Review Pull Request Goal Prompt

> Testable claims for the `goal.review_pull_request` prompt augmentation.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r REVIEW-PR-001`).

## Scope and finding evidence (#3897)

- [x] **REVIEW-PR-001** — The seeded `goal.review_pull_request` row and
  `Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT` SHALL
  reference the same template source
  (`Prompts::GoalReviewPullRequest::TEMPLATE`) so the two bindings
  cannot drift at code-load time. The seeded row SHALL declare the same
  variables (`base_prompt`, `repo`, `pr_number`) as
  `Prompts::GoalReviewPullRequest::VARIABLES`.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`,
  `app/temporal/activities/run_agent_activity.rb`,
  `db/seeds/prompts.rb`.
  *Tests:* `spec/db/prompt_seeds_spec.rb`,
  `spec/services/prompts/goal_review_pull_request_spec.rb`.

- [x] **REVIEW-PR-002** — The review-goal prompt SHALL explicitly enumerate
  five review-scope axes the reviewer must walk in order — PR base/head
  diff, changed behavior, removed safeguards, caller/callee compatibility,
  and project instructions — before falling through to the existing
  performance/security/style/scope/linkage categories. Removed safeguards
  SHALL be an explicit, separate axis (not bundled into changed behavior),
  and the legacy categories SHALL be preserved verbatim alongside the new
  axes.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`
  (`TEMPLATE`).
  *Tests:* `spec/db/prompt_seeds_spec.rb` ("review scope and finding
  evidence"), `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("review scope").

- [x] **REVIEW-PR-003** — The review-goal prompt SHALL require every
  inline-comment finding to cite three pieces of evidence — a triggering
  state, the resulting incorrect behavior or concrete cost, and a
  supporting code location (file path plus line number) — and SHALL
  require the reviewer to recheck each finding against the surrounding
  code before posting, dropping the finding if the recheck no longer
  supports it. The prompt SHALL NOT use the new evidence bar as a license
  to invent nitpicks; a clean PR with zero issues remains a valid outcome.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`
  (`TEMPLATE`).
  *Tests:* `spec/db/prompt_seeds_spec.rb`, `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("finding evidence bar").

## Contract preservation (#3897)

- [x] **REVIEW-PR-004** — The review-goal prompt SHALL preserve the
  clean-review signal Paid uses to stop the review loop: a clean review
  body MUST begin with the exact phrase "Generated no new comments." and
  MUST include the exact HTML marker
  `<!-- paid-review-clean -->` (= `ScanPaidPrsActivity::PAID_REVIEW_CLEAN_MARKER`).
  The same string MUST appear in the seed, the code fallback, and the
  shared source. If `ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN` ever
  changes, the shared source MUST be updated in the same change.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Tests:* `spec/db/prompt_seeds_spec.rb` ("goal.review_pull_request
  clean-PR phrase coupling"), `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("review contract preservation").

- [x] **REVIEW-PR-005** — The review-goal prompt SHALL require the reviewer
  to post exactly one PR review via `/pulls/<n>/reviews`, SHALL forbid
  `event: REQUEST_CHANGES` and `event: APPROVE`, and SHALL require review
  payloads to be submitted via a temp file with `--data-binary @file`
  (regression for #839). Standalone issue comments via
  `/issues/<n>/comments` SHALL NOT satisfy the review requirement.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`.
  *Tests:* `spec/db/prompt_seeds_spec.rb`, `spec/services/prompts/goal_review_pull_request_spec.rb`.

- [x] **REVIEW-PR-006** — The review-goal prompt SHALL forbid praise-only
  inline comments ("looks good", "nice refactor", etc.) and SHALL
  reserve inline comments exclusively for actionable changes. The
  prompt SHALL continue to state that a clean PR with zero issues is a
  valid and expected outcome.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`.
  *Tests:* `spec/db/prompt_seeds_spec.rb`, `spec/services/prompts/goal_review_pull_request_spec.rb`.

## Rendering integrity

- [x] **REVIEW-PR-007** — When supplied with the declared variables
  (`base_prompt`, `repo`, `pr_number`), the review-goal template SHALL
  render with no unresolved `{{...}}` placeholders and SHALL NOT
  reference any undeclared variables.
  *Code:* `app/services/prompts/goal_review_pull_request.rb`.
  *Tests:* `spec/db/prompt_seeds_spec.rb` ("prompt goal.review_pull_request"
  — renders without leaving unresolved {{variables}}, declares every
  {{placeholder}} that appears in its template), `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("renders all declared placeholders").

## Dependency capability and truthful limited review (#5398)

- [x] **REVIEW-PR-008** — Before Ruby/Rails validation, the review-goal
  prompt SHALL require `bundle check` to establish the selected isolated
  review environment's locked-bundle capability. When unavailable, it SHALL
  permit at most one visible, frozen dependency-preparation command with a
  finite deadline below the review idle bound and no Bundler retries. The
  command SHALL NOT hide output, and the prompt SHALL forbid host execution,
  allowance increases, and repeated installation attempts.
  *Code:* `app/services/prompts/goal_review_pull_request.rb` (`TEMPLATE`).
  *Tests:* `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("dependency preparation").

- [x] **REVIEW-PR-009** — When locked dependencies cannot be prepared within
  that one bounded attempt, including an unavailable git dependency, a
  silent/stalled command, or another terminal setup failure, the review-goal
  prompt SHALL permit only a limited static/diff review. Its required body
  SHALL name the bounded limitation, state that no local tests ran, and state
  that it is not clean-review or merge authorization. It SHALL submit one
  `COMMENT` review without the clean marker; if the diff is unavailable, it
  SHALL instead expose an actionable unavailable stop. External CI and source
  acceptance remain distinct evidence.
  *Code:* `app/services/prompts/goal_review_pull_request.rb` (`TEMPLATE`).
  *Tests:* `spec/services/prompts/goal_review_pull_request_spec.rb`
  ("limited review publication").
