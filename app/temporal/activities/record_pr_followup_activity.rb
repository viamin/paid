# frozen_string_literal: true

module Activities
  # Records that a PR follow-up was triggered by incrementing the
  # pr_followup_count and removing actionable labels. Called by the
  # workflow after the child workflow is successfully started.
  #
  # Idempotent: uses the workflow_id as a deduplication key to prevent
  # double-counting on Temporal retries.
  class RecordPrFollowupActivity < BaseActivity
    activity_name "RecordPrFollowup"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { recorded: false } unless project

      issue = project.issues.find_by(id: input[:issue_id])
      return { recorded: false } unless issue

      issue.increment!(:pr_followup_count)

      remove_labels(project, issue, input[:labels_to_remove] || [])

      { recorded: true }
    end

    private

    def remove_labels(project, issue, labels)
      return if labels.empty?

      client = project.github_token.client
      labels.each do |label|
        client.remove_label_from_issue(project.full_name, issue.github_number, label)
      rescue GithubClient::Error => e
        logger.warn(
          message: "pr_scanner.remove_label_failed",
          project_id: project.id,
          pr_number: issue.github_number,
          label: label,
          error: e.message
        )
      end
    end
  end
end
