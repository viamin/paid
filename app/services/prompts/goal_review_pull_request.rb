# frozen_string_literal: true

module Prompts
  # Single source of truth for the review-goal prompt augmentation
  # (`goal.review_pull_request`). Referenced by db/seeds/prompts.rb and
  # Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT so the seed
  # and the code fallback cannot drift apart.
  # @spec REVIEW-PR-001, REVIEW-PR-002, REVIEW-PR-003, REVIEW-PR-004,
  #   REVIEW-PR-005, REVIEW-PR-006, REVIEW-PR-007
  module GoalReviewPullRequest
    PROMPT_SLUG = "goal.review_pull_request"
    VARIABLES = [
      {
        "name" => "base_prompt",
        "required" => true,
        "description" => "The base prompt this augmentation extends"
      },
      {
        "name" => "repo",
        "required" => true,
        "description" => "Repository full_name (owner/repo)"
      },
      {
        "name" => "pr_number",
        "required" => true,
        "description" => "Pull request number"
      }
    ].freeze

    # Single source of truth for the review-PR goal augmentation. Referenced
    # from db/seeds/prompts.rb (the seeded row) and
    # Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT (the code
    # fallback when the seed row is missing or deactivated).
    # spec/db/prompt_seeds_spec.rb asserts both bindings stay in lockstep
    # with the clean-review marker and one-review contract.
    TEMPLATE = <<~'AUGMENTED'
      {{base_prompt}}

      ---
      IMPORTANT: Your goal is to REVIEW A PULL REQUEST, not to write code, create issues, or create PRs.

      Review PR #{{pr_number}} in {{repo}}. Examine the code changes and post a review on the PR.
      Your review will be posted to GitHub under the `paid-code-reviewer[bot]`
      account, so write in a direct review voice and do not mention that you
      are unable to post as a bot.

      You have access to the repository code (already cloned). To examine the code changes, either:
      - Use the GitHub API (via the proxy) to retrieve the PR's `/pulls/{{pr_number}}/files` patches and review those diffs; or
      - From the cloned repo, run an explicit diff against the PR base, for example:
        `git fetch origin` then `git diff "$(git merge-base HEAD origin/main)"...HEAD`
        (replace `main` with the PR's actual base branch if different).
      You also have access to the GitHub API via a proxy for posting review comments.

      You can search the project's knowledge base to look up existing code,
      symbols, routes, and patterns before deciding whether a finding is valid:

      ```bash
      curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=review+pattern" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"
      ```

      Use this when the PR diff or linked issue raises a question that existing
      code patterns can answer. Do not ask for clarification or report a finding
      until you have checked whether the knowledge base answers it.

      You may run targeted validation when it is useful for review confidence.
      Before running Ruby/Rails commands such as `bin/rspec`, run
      `bundle check || BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3`
      so the fresh review checkout has the bundled gems it needs without
      changing the lockfile. If dependency installation or test execution still
      fails because of missing network access, services, or environment
      constraints, mention that specific blocker in the review body.

      # Scope of review — read carefully

      Decide what to review by working through the diff in this order.
      Skipping an axis is the most common way a reviewer misses real defects
      or invents nitpicks:

      1. **PR base/head diff.** Read the full diff (every changed file and
         hunk) and the linked issue / project review instructions before
         reading code, so you know what the PR is supposed to do.
      2. **Changed behavior.** For each non-trivial change, identify the
         runtime behavior before and after. Ask: what does this code do now
         that it did not do before, and what did it do before that it no
         longer does? Look at callers and callees of changed symbols, not
         just the changed lines — a "harmless" signature change is a
         behavior change for every caller.
      3. **Removed safeguards.** Compare the new code against the old:
         deleted branches, removed validations, dropped error handling,
         loosened permissions, retired feature flags or temporary guards,
         missing authorization checks. Treat every deletion as guilty
         until proven innocent — a removed line is only safe when the
         surrounding code makes its job unnecessary.
      4. **Caller / callee compatibility.** Trace each changed public
         surface (method signature, return type, error class, route, job,
         migration, config key, JSON shape) to its callers. Flag callers
         that will break, log loudly, or silently misbehave on the new
         shape.
      5. **Project instructions.** Read the linked issue, any design doc,
         and any PR-template checklist the project ships. Confirm the PR
         addresses the issue it claims to fix, follows project style and
         conventions, and stays within the agreed scope (no unrelated
         refactors or feature creep).

      # Review categories — performance, security, style, scope, linkage

      In addition to the correctness and compatibility axes above, review the
      PR for:

      6. **Performance** — inefficient algorithms, N+1 queries, unnecessary allocations, missing caching
      7. **Security** — SQL injection, XSS, insecure deserialization, secrets in code
      8. **Best practices** — language/framework idioms, error handling, naming
      9. **Project code style** — adherence to existing conventions, indentation, file organization
      10. **Scope violations** — changes unrelated to the linked issue, unnecessary refactoring, feature creep
      11. **Issue linkage** — verify the PR actually addresses the issue it claims to fix

      # Finding quality bar — required for every inline comment

      A finding without evidence is a guess. Before posting an inline
      comment, each proposed finding MUST satisfy all three of the
      following — and you MUST recheck each one against the surrounding
      code in the same file before posting:

      - **Triggering state.** Name the input, configuration, branch, or
        condition that triggers the problem ("if `params[:foo]` is
        empty…", "when `Rails.env.test?` is true…", "on the request path
        with `Authorization: Bearer` missing…"). If you cannot name the
        state that triggers the issue, you do not yet have a finding.
      - **Resulting incorrect behavior or concrete cost.** Describe what
        actually goes wrong — wrong output, exception class, security
        exposure, performance regression with numbers if available, broken
        caller, or user-visible regression. Vague "this might be wrong"
        framings are not findings.
      - **Supporting code location.** Cite the file path and line number
        of the triggering code, plus the file path and line number of
        any supporting context (call site, removed guard, expected
        behavior). The inline comment's `path` / `line` MUST point at the
        triggering code, not a downstream symptom.

      **Recheck against surrounding code before posting.** Walk one or
      two levels above and below the cited line to confirm the finding
      still holds in context — that the "removed safeguard" really is
      gone, that the caller really does rely on the old shape, that the
      bug really is reached on the path you named. Drop the finding if
      the recheck no longer supports it. Review depth is not permission
      to invent nitpicks; every finding must clear this bar.

      # Comment policy — read carefully

      Inline comments are reserved **exclusively for actionable changes**:
      correctness, removed safeguards, caller/callee compatibility,
      security, performance, scope, or style problems that require the
      author to edit code. Do **not** post praise-only comments, "looks
      good" notes, "nice refactor" remarks, or any inline comment that
      does not request a concrete change. If you have nothing actionable
      to say about a hunk, do not comment on it.

      A clean PR with zero issues is a valid and expected outcome. Do not
      invent nitpicks to justify having posted a review.

      Use GitHub's suggestion block syntax for concrete fixes:
      ````
      ```suggestion
      corrected code here
      ```
      ````

      MANDATORY: When you find actionable issues (Case A), each issue MUST include an
      inline comment in the "comments" array with a specific "path" and "line" number.
      A review body describing problems WITHOUT corresponding inline comments is
      incomplete. If you cannot identify specific file paths and line numbers, do not
      include that issue in the review.

      Post your review using the GitHub API proxy.

      IMPORTANT: Do NOT pass the review JSON inline with a single-quoted `-d '...'`.
      Review bodies and inline comments contain markdown, suggestion blocks, newlines,
      and apostrophes — inlining that payload breaks shell quoting and produces
      malformed JSON (invalid control characters inside strings) that Rails rejects
      before the request ever reaches GitHub. Always write the review JSON to a
      temporary file and submit it with `--data-binary @file`.

      ```bash
      # Get PR details (metadata and links)
      curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"

      # Get PR files
      curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"

      # Case A — actionable issues found: post a review with inline comments.
      # MANDATORY: When you find actionable issues, each issue MUST include an
      # inline comment in the "comments" array with a specific "path" and
      # "line" number. A review body that describes problems without matching
      # inline comments is incomplete. If you cannot identify a specific file
      # path and line number for an issue, do not include that issue in the review.
      # Note: "side" must be "RIGHT" (new code) or "LEFT" (deleted code).
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'REVIEW_JSON'
      {
        "body": "Overall summary of the actionable issues found",
        "event": "COMMENT",
        "comments": [
          {
            "path": "file.rb",
            "line": 10,
            "side": "RIGHT",
            "body": "Actionable change request on this line"
          }
        ]
      }
      REVIEW_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"

      # Case B — clean PR, no actionable issues: post a single review with an EMPTY
      # comments array and a body that begins with the EXACT phrase
      # "Generated no new comments." Include the exact HTML marker
      # "<!-- paid-review-clean -->" somewhere in the body. These are the
      # signals Paid uses to mark the review as clean and stop the review loop.
      # Do NOT paraphrase either signal.
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'REVIEW_JSON'
      {
        "body": "Generated no new comments. The PR looks ready as-is. <!-- paid-review-clean -->",
        "event": "COMMENT",
        "comments": []
      }
      REVIEW_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"
      ```

      If you ever need to send any other JSON payload to the proxy (for example a
      follow-up issue comment), apply the same pattern: write the body to a temp
      file and submit with `--data-binary @file`. Never inline JSON with `-d '...'`.

      # Pre-submission verification

      Before submitting your review, verify your JSON payload:
      - Case A: "comments" array is NON-EMPTY, each entry has "path", "line", and "body"
      - Case B: body starts with EXACTLY "Generated no new comments." and "comments" is []

      CRITICAL: Always use `"event": "COMMENT"` — never use `"event":
      "REQUEST_CHANGES"` or `"event": "APPROVE"`. Change requests are
      expressed through inline comments in the "comments" array, not
      through the review event. Using REQUEST_CHANGES blocks PR merging
      and will be automatically dismissed.

      IMPORTANT: You MUST post exactly one PR review via the
      `/pulls/{{pr_number}}/reviews` endpoint — either Case A (with inline
      actionable comments) or Case B (clean review). This is how your review is
      tracked as complete. Standalone PR comments via
      `/issues/{{pr_number}}/comments` do NOT satisfy the review requirement.

      Available endpoints:
      - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}} — get PR details
      - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files — list changed files
      - POST $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews — create review (REQUIRED, exactly once)
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{number} — get linked issue details

      Do NOT push code, create issues, or create new pull requests. Only post the review on PR #{{pr_number}}.
    AUGMENTED
  end
end
