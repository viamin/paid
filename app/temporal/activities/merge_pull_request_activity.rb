# frozen_string_literal: true

module Activities
  # Merges a pull request using the project's configured merge method.
  # Idempotent: checks if the PR is already merged before attempting.
  # Updates the issue's pr_review_phase to "merged" on success.
  class MergePullRequestActivity < BaseActivity
    activity_name "MergePullRequest"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      issue = Issue.find(input[:issue_id])

      client = project.github_token.client
      pr_data = client.pull_request(project.full_name, pr_number)

      if pr_data.merged_at
        logger.info(
          message: "pr_review.already_merged",
          project_id: project.id,
          pr_number: pr_number
        )
      else
        client.merge_pull_request(
          project.full_name, pr_number,
          merge_method: project.merge_method
        )
        logger.info(
          message: "pr_review.merged",
          project_id: project.id,
          pr_number: pr_number,
          merge_method: project.merge_method
        )
      end

      issue.update!(pr_review_phase: "merged")

      { merged: true, pr_number: pr_number }
    end
  end
end
