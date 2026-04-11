# frozen_string_literal: true

module Activities
  # Transitions a PR from "escalated" back to "ready" when the owner
  # dismisses the escalation (e.g. by adding the paid-dismiss-escalation
  # label). Removes the escalation label and the dismiss trigger label.
  class DismissEscalationActivity < BaseActivity
    activity_name "DismissEscalation"

    PAID_ESCALATED_LABEL = "paid-escalated"
    DISMISS_ESCALATION_LABEL = "paid-dismiss-escalation"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { dismissed: false } unless issue
      return { dismissed: false } unless issue.escalated_phase?

      project = issue.project
      client = project.github_token.client

      issue.update!(pr_review_phase: "ready")

      remove_label(client, project, issue, DISMISS_ESCALATION_LABEL)
      remove_label(client, project, issue, PAID_ESCALATED_LABEL)

      logger.info(
        message: "pr_review.escalation_dismissed",
        issue_id: issue.id,
        pr_number: issue.github_number
      )

      { dismissed: true }
    end

    private

    def remove_label(client, project, issue, label)
      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.remove_label_failed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        label: label,
        error: e.message
      )
    end
  end
end
