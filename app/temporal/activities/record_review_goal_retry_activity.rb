# frozen_string_literal: true

module Activities
  # Increments the review_goal_retry_count on the issue to track how many
  # times a failed review-goal run has been retried. This counter is
  # independent of max_review_rounds (which counts completed reviews) and
  # is used by the scanner to cap retries and escalate to the owner.
  class RecordReviewGoalRetryActivity < BaseActivity
    activity_name "RecordReviewGoalRetry"

    def execute(input)
      issue = Issue.find(input[:issue_id])
      issue.increment!(:review_goal_retry_count)

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
