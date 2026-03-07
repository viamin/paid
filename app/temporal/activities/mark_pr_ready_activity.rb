# frozen_string_literal: true

module Activities
  # Marks a draft pull request as ready for review and updates the
  # issue's pr_review_phase to "ready". Idempotent: checks if PR
  # is already non-draft before calling the GitHub API. Only updates
  # the issue phase when GitHub confirms the PR is non-draft.
  class MarkPrReadyActivity < BaseActivity
    activity_name "MarkPrReady"

    PAID_READY_LABEL = "paid-ready"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      issue = Issue.find(input[:issue_id])

      client = project.github_token.client
      pr_data = client.pull_request(project.full_name, pr_number)

      if pr_data.draft
        result = client.mark_pull_request_ready(project.full_name, pr_number)
        unless result["isDraft"] == false
          logger.warn(
            message: "pr_review.mark_ready_failed",
            project_id: project.id,
            pr_number: pr_number
          )
          return { marked_ready: false, pr_number: pr_number }
        end

        logger.info(
          message: "pr_review.marked_ready",
          project_id: project.id,
          pr_number: pr_number
        )
      else
        logger.info(
          message: "pr_review.already_ready",
          project_id: project.id,
          pr_number: pr_number
        )
      end

      issue.update!(pr_review_phase: "ready")

      add_phase_label(client, project, pr_number, PAID_READY_LABEL)

      { marked_ready: true, pr_number: pr_number }
    end

    private

    def add_phase_label(client, project, pr_number, label)
      client.add_labels_to_issue(project.full_name, pr_number, [ label ])
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.add_label_failed",
        project_id: project.id,
        pr_number: pr_number,
        label: label,
        error: e.message
      )
    end
  end
end
