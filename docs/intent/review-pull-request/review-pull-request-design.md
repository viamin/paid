---
parent: PAID
prefix: REVIEW-PR
---

# Low-Level Design: Review Pull Request Goal Prompt

> Companion to the high-level design (`docs/high-level-design.md`). Defines
> the review-goal prompt augmentation (`goal.review_pull_request`) the agent
> uses to inspect a pull request and post a single GitHub PR review under the
> `paid-code-reviewer[bot]` identity.

## Purpose

The review goal is the prompt that drives every containerized agent run whose
goal is `review_pull_request`. The goal augmentation is rendered on top of a
base prompt by `Activities::RunAgentActivity#augment_prompt_for_review_goal`
(resolving the seeded `goal.review_pull_request` row, with a code-side
fallback). The augmentation must cover the same review policy in both
bindings so a missing or deactivated seed row cannot degrade the review.

This LLD scopes the prompt content itself — the reviewer scope, the
finding-evidence bar, and the contract that the agent must satisfy when
posting a review. It does **not** scope the review-loop machinery
(`ScanPaidPrsActivity`, the draft-review-round state machine, the
`paid-code-reviewer[bot]` GitHub App) — those are owned by the PR lifecycle
segments.

## Single source of truth

The augmentation template and its declared variables live in
`app/services/prompts/goal_review_pull_request.rb`
(`Prompts::GoalReviewPullRequest::TEMPLATE` and `::VARIABLES`). That module
is referenced from:

- `db/seeds/prompts.rb` — the seeded `goal.review_pull_request` row that
  is current in production prompts.
- `Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT` — the code
  fallback used when the seeded row is missing or deactivated.

The two bindings cannot drift apart at code-load time: they reference the
same `String` object. `spec/db/prompt_seeds_spec.rb` holds a coupling spec
that asserts the seeded row's current version, the code fallback, and the
shared source all carry the same clean-review markers, request-events
prohibition, scope and finding-evidence sections, and "no nitpicks"
language. `spec/services/prompts/goal_review_pull_request_spec.rb` holds
the behavior-focused assertions on the shared source itself.

## Review scope

The augmentation explicitly enumerates the axes a reviewer must walk
through the diff in order. Skipping an axis is the most common way a
reviewer misses real defects or invents nitpicks:

1. **PR base/head diff.** Read the full diff (every changed file and
   hunk) and the linked issue / project review instructions before
   reading code, so you know what the PR is supposed to do.
2. **Changed behavior.** For each non-trivial change, identify the
   runtime behavior before and after. Callers and callees of changed
   symbols matter as much as the changed lines themselves — a
   "harmless" signature change is a behavior change for every caller.
3. **Removed safeguards.** Compare the new code against the old:
   deleted branches, removed validations, dropped error handling,
   loosened permissions, retired feature flags or temporary guards,
   missing authorization checks. Treat every deletion as guilty until
   proven innocent.
4. **Caller / callee compatibility.** Trace each changed public
   surface (method signature, return type, error class, route, job,
   migration, config key, JSON shape) to its callers. Flag callers
   that will break, log loudly, or silently misbehave on the new
   shape.
5. **Project instructions.** Read the linked issue, any design doc,
   and any PR-template checklist the project ships. Confirm the PR
   addresses the issue it claims to fix, follows project style and
   conventions, and stays within the agreed scope.

After walking those axes, the augmentation also covers the existing
review categories — performance, security, best practices, project code
style, scope violations, and issue linkage. Correctness and compatibility
are additive; the legacy categories are preserved.

## Finding evidence bar

Every inline comment must clear the same evidence bar. A finding without
evidence is a guess. Before posting an inline comment, the reviewer must
name:

- **Triggering state.** The input, configuration, branch, or condition
  that triggers the problem ("if `params[:foo]` is empty…", "when
  `Rails.env.test?` is true…", "on the request path with
  `Authorization: Bearer` missing…").
- **Resulting incorrect behavior or concrete cost.** Wrong output,
  exception class, security exposure, performance regression with
  numbers if available, broken caller, or user-visible regression.
  Vague "this might be wrong" framings are not findings.
- **Supporting code location.** The file path and line number of the
  triggering code, plus the file path and line number of any
  supporting context (call site, removed guard, expected behavior).
  The inline comment's `path` / `line` must point at the triggering
  code, not a downstream symptom.

The reviewer must recheck each finding against the surrounding code
(walk one or two levels above and below the cited line) before posting
and drop the finding if the recheck no longer supports it. Review
depth is not permission to invent nitpicks; every finding must clear
this bar.

## Contract preserved

The prompt and its fallback must keep the contract that ties the
agent's output to the rest of the review loop:

- **Exactly one PR review.** The reviewer must post exactly one
  review via the `/pulls/<n>/reviews` endpoint — either Case A (with
  inline actionable comments) or Case B (clean review). Standalone
  issue comments do not satisfy the review requirement.
- **Clean-review signal.** A clean review must use an empty
  `comments` array and a body that begins with the exact phrase
  `Generated no new comments.` and includes the exact HTML marker
  `<!-- paid-review-clean -->`. The phrase is matched (case-insensitive)
  by `ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN`; the marker is the
  audit signal `ScanPaidPrsActivity::PAID_REVIEW_CLEAN_MARKER`. If
  either matcher changes, update the shared source together or the
  clean-review loop will silently fail to terminate.
- **`event: COMMENT` only.** The reviewer must use `"event": "COMMENT"`
  and never `"event": "REQUEST_CHANGES"` or `"event": "APPROVE"`.
  Change requests are expressed through inline comments in the
  `comments` array; using `REQUEST_CHANGES` blocks PR merging and is
  automatically dismissed.
- **No nitpicks.** Inline comments are reserved exclusively for
  actionable changes. Praise-only comments and "looks good" notes are
  not findings. A clean PR with zero issues is a valid and expected
  outcome.
- **Submission via `--data-binary @file`.** Review payloads are written
  to a temp file and submitted with `--data-binary @file`. Inline
  `-d '...'` payloads break shell quoting on multiline markdown and
  apostrophes and produce malformed JSON that Rails rejects before
  the request reaches GitHub (regression for #839).