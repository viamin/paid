# frozen_string_literal: true

module Activities
  # Lightweight activity that checks the GitHub API rate limit remaining
  # for a project. Used by GitHubPollWorkflow to coordinate budget across
  # sequential activities and skip non-critical work when budget is low.
  class CheckRateLimitActivity < BaseActivity
    activity_name "CheckRateLimit"

    # Default threshold below which non-critical activities should be skipped.
    # Leaves headroom for agent runs triggered by the poll cycle.
    DEFAULT_LOW_THRESHOLD = 100

    def execute(input)
      project_id = input[:project_id]
      threshold = input[:threshold] || DEFAULT_LOW_THRESHOLD

      project = Project.find_by(id: project_id)
      return { rate_limit_remaining: 0, rate_limit_low: true, project_missing: true } unless project

      client = project.github_token.client
      remaining = client.rate_limit_remaining

      low = remaining < threshold

      if low
        logger.warn(
          message: "rate_limit.budget_low",
          project_id: project_id,
          remaining: remaining,
          threshold: threshold
        )
      end

      { rate_limit_remaining: remaining, rate_limit_low: low }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end
  end
end
