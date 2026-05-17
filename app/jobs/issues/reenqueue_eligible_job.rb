# frozen_string_literal: true

module Issues
  class ReenqueueEligibleJob < ApplicationJob
    queue_as :default

    def perform(issue_id)
      issue = Issue.includes(:project).find_by(id: issue_id)
      return unless issue
      return if issue.is_pull_request?
      return unless issue.paid_state.in?(%w[new planning failed completed])
      return unless AutoPickProjectGate.call(issue.project)

      EnqueueEligible.call(issue, project: issue.project, skip_project_gate: true)
    rescue => e
      Rails.logger.error(
        message: "enqueue_eligible.issue_state_change_failed",
        issue_id: issue_id,
        error: e.message
      )
    end
  end
end
