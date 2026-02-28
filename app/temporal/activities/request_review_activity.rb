# frozen_string_literal: true

module Activities
  # Requests review from specified GitHub users on a pull request.
  # Checks existing pending reviewers first to avoid duplicate requests.
  # Handles 422 errors gracefully (e.g. Copilot not enabled on the repo).
  class RequestReviewActivity < BaseActivity
    activity_name "RequestReview"

    COPILOT_LOGIN = "copilot"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      reviewers = input[:reviewers] || []
      return { requested: [] } if reviewers.empty?

      client = project.github_token.client

      already_pending = fetch_pending_reviewers(client, project, pr_number)
      needed = reviewers.reject { |r| already_pending.include?(r.downcase) }
      return { requested: [], already_pending: already_pending } if needed.empty?

      client.request_pull_request_review(project.full_name, pr_number, reviewers: needed)

      logger.info(
        message: "pr_review.review_requested",
        project_id: project.id,
        pr_number: pr_number,
        reviewers: needed
      )

      { requested: needed }
    rescue GithubClient::ApiError => e
      if e.status == 422
        logger.warn(
          message: "pr_review.request_review_unprocessable",
          project_id: input[:project_id],
          pr_number: pr_number,
          reviewers: reviewers,
          error: e.message
        )
        { requested: [], error: e.message }
      else
        raise
      end
    end

    private

    def fetch_pending_reviewers(client, project, pr_number)
      review_requests = client.pull_request_review_requests(project.full_name, pr_number)
      review_requests[:users].map(&:downcase)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.fetch_pending_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      []
    end
  end
end
