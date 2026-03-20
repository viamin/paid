# frozen_string_literal: true

module Activities
  class CompleteReviewGoalActivity < BaseActivity
    activity_name "CompleteReviewGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      # Reload to pick up any review_posted_at set by the proxy during execution.
      agent_run.reload

      if agent_run.review_posted_at.blank?
        logger.warn(
          message: "agent_execution.review_goal_no_review_posted",
          agent_run_id: agent_run_id,
          pr_number: agent_run.source_pull_request_number
        )
        agent_run.fail!(error: "No review was posted on PR ##{agent_run.source_pull_request_number}")

        raise Temporalio::Error::ApplicationError.new(
          "No review was posted on PR ##{agent_run.source_pull_request_number}",
          type: "ReviewNotPosted",
          non_retryable: true
        )
      end

      # Don't set pull_request_number for review runs — that field represents
      # the PR produced by the run. Review runs use source_pull_request_number
      # to track which PR was reviewed, keeping the two semantics distinct.
      agent_run.complete!
      agent_run.log!("system", "Completed: review goal finished for PR ##{agent_run.source_pull_request_number}")

      logger.info(
        message: "agent_execution.review_goal_completed",
        agent_run_id: agent_run_id,
        pr_number: agent_run.source_pull_request_number,
        review_posted: agent_run.review_posted_at.present?
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run_id, success: true }
    end
  end
end
