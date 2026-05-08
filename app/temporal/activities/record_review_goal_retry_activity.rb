# frozen_string_literal: true

module Activities
  # Increments the review_goal_retry_count on the issue to track how many
  # times a failed review-goal run has been retried. This counter is
  # independent of max_review_rounds (which counts completed reviews) and
  # is used by the scanner to cap retries and escalate to the owner.
  #
  # Idempotent: uses the expected_review_goal_retry_count parameter to
  # prevent double-counting on Temporal retries. The increment only
  # applies when the current count matches the expected value.
  class RecordReviewGoalRetryActivity < BaseActivity
    activity_name "RecordReviewGoalRetry"

    def execute(input)
      issue = Issue.find(input[:issue_id])

      expected_count = input[:expected_review_goal_retry_count]
      incremented = false
      before_count = issue.review_goal_retry_count
      if expected_count
        issue.with_lock do
          issue.reload
          before_count = issue.review_goal_retry_count
          if issue.review_goal_retry_count == expected_count
            issue.increment!(:review_goal_retry_count)
            incremented = true
          end
        end
      else
        issue.increment!(:review_goal_retry_count)
        incremented = true
      end

      OrchestrationDecision.record(
        project: issue.project,
        issue: issue,
        decision_point: "review_goal_retry",
        action: "retry",
        status: incremented ? "applied" : "noop",
        signals: {
          trigger: "review_goal_retry",
          expected_review_goal_retry_count: expected_count,
          current_review_goal_retry_count: before_count
        },
        result: {
          review_goal_retry_count: issue.review_goal_retry_count
        }
      )

      logger.info(
        message: "pr_scanner.review_goal_retry_recorded",
        issue_id: issue.id,
        pr_number: issue.github_number,
        review_goal_retry_count: issue.review_goal_retry_count
      )

      { issue_id: issue.id, review_goal_retry_count: issue.review_goal_retry_count }
    end
  end
end
