# frozen_string_literal: true

module Activities
  # Transitions a PR issue to the "escalated" phase. Used when the draft
  # review limit is reached and the owner needs to intervene.
  class MarkEscalatedActivity < BaseActivity
    activity_name "MarkEscalated"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { updated: false } unless issue

      project = issue.project
      issue.update!(pr_review_phase: "escalated")

      add_phase_label(project, issue)

      logger.info(
        message: "pr_review.marked_escalated",
        issue_id: issue.id,
        pr_number: issue.github_number
      )

      { updated: true }
    end

    private

    def add_phase_label(project, issue)
      client = project.github_token.client
      client.add_labels_to_issue(
        project.full_name,
        issue.github_number,
        [ Activities::ScanPaidPrsActivity::PAID_ESCALATED_LABEL ]
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.add_label_failed",
        project_id: project.id,
        pr_number: issue.github_number,
        label: Activities::ScanPaidPrsActivity::PAID_ESCALATED_LABEL,
        error: e.message
      )
    end
  end
end
