# frozen_string_literal: true

module Activities
  class DispatchClaudeReviewActivity < BaseActivity
    activity_name "DispatchClaudeReview"

    EVENT_TYPE = "claude-review"
    ACTION_NAME = "Claude Code Review"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = Integer(input[:pr_number])

      return { dispatched: false, reason: "reviews_disabled" } unless project.review_enabled?
      return { dispatched: false, reason: "ci_action_disabled" } unless project.review_method_enabled?("ci_action")
      return { dispatched: false, reason: "action_name_mismatch" } unless claude_review_action?(project)

      project.github_token.client.dispatch_repository_event(
        project.full_name,
        event_type: EVENT_TYPE,
        client_payload: { pr_number: pr_number }
      )

      logger.info(
        message: "pr_review.claude_review_dispatched",
        project_id: project.id,
        pr_number: pr_number,
        event_type: EVENT_TYPE
      )

      { dispatched: true, event_type: EVENT_TYPE, pr_number: pr_number }
    end

    private

    def claude_review_action?(project)
      project.review_method_config("ci_action").to_h["action_name"] == ACTION_NAME
    end
  end
end
