# frozen_string_literal: true

module Activities
  class CompleteReviewGoalActivity < BaseActivity
    activity_name "CompleteReviewGoal"

    # Marks the review run as completed unconditionally. We don't verify
    # that the agent actually posted review comments because:
    # 1. The proxy tracks issue creation but not review creation (yet)
    # 2. The agent may have legitimately found nothing to comment on
    # 3. Review failures surface as agent-level errors handled upstream
    # TODO(#232): Track successful POST /pulls/:number/reviews calls in
    # the proxy to enable conditional completion verification.
    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      # Don't set pull_request_number for review runs — that field represents
      # the PR produced by the run. Review runs use source_pull_request_number
      # to track which PR was reviewed, keeping the two semantics distinct.
      agent_run.complete!
      agent_run.log!("system", "Completed: review goal finished for PR ##{agent_run.source_pull_request_number}")

      logger.info(
        message: "agent_execution.review_goal_completed",
        agent_run_id: agent_run_id,
        pr_number: agent_run.source_pull_request_number
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run_id, success: true }
    end
  end
end
