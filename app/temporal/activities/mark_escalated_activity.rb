# frozen_string_literal: true

module Activities
  # Transitions a PR issue to the "escalated" phase. Used when the draft
  # review limit is reached and the owner needs to intervene.
  class MarkEscalatedActivity < BaseActivity
    activity_name "MarkEscalated"

    PAID_ESCALATED_LABEL = "paid-escalated"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { updated: false } unless issue

      project = issue.project
      client = project.github_token.client
      issue.update!(pr_review_phase: "escalated")

      add_phase_label(client, project, issue.github_number, PAID_ESCALATED_LABEL)

      logger.info(
        message: "pr_review.marked_escalated",
        issue_id: issue.id,
        pr_number: issue.github_number
      )

      { updated: true }
    end
  end
end
