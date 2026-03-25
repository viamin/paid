# frozen_string_literal: true

module Activities
  # Merges a pull request using the project's configured merge method.
  # Idempotent: checks if the PR is already merged before attempting.
  # Updates the issue's pr_review_phase to "merged" on success.
  # Handles expected merge failures (409/405/422) gracefully so the
  # poll loop can continue and re-scan later.
  class MergePullRequestActivity < BaseActivity
    activity_name "MergePullRequest"

    EXPECTED_MERGE_STATUSES = [ 405, 409, 422 ].freeze
    PAID_AUTO_MERGED_LABEL = "paid-auto-merged"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      issue = Issue.find(input[:issue_id])

      unless project.auto_merge_enabled?
        logger.info(
          message: "pr_review.auto_merge_disabled",
          project_id: project.id,
          pr_number: pr_number
        )
        return { merged: false, skipped: true, pr_number: pr_number }
      end

      client = project.github_token.client
      pr_data = client.pull_request(project.full_name, pr_number)

      merged = if pr_data.merged_at
        logger.info(
          message: "pr_review.already_merged",
          project_id: project.id,
          pr_number: pr_number
        )
        true
      else
        attempt_merge(client, project, pr_number)
      end

      if merged
        issue.update!(pr_review_phase: "merged")
        # Only label PRs that this activity actually merged — already-merged
        # PRs may have been merged manually by a human.
        add_phase_label(client, project, pr_number, PAID_AUTO_MERGED_LABEL) unless pr_data.merged_at
      end

      { merged: merged, pr_number: pr_number }
    end

    private

    def attempt_merge(client, project, pr_number)
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
      true
    rescue GithubClient::ApiError => e
      raise unless EXPECTED_MERGE_STATUSES.include?(e.status)

      logger.warn(
        message: "pr_review.merge_failed_expected",
        project_id: project.id,
        pr_number: pr_number,
        status: e.status,
        error: e.message
      )
      false
    end
  end
end
