# frozen_string_literal: true

module Activities
  # Lightweight activity that checks the GitHub API rate limit remaining
  # for a project. Used by GitHubPollWorkflow to coordinate budget across
  # sequential activities and skip non-critical work when budget is low.
  #
  # Because projects resolve to either a GitHub App installation token
  # (15,000/hr per installation) or a per-account PAT (5,000/hr shared
  # across projects), this probe also records the observed quota against
  # the project's credential-scoped health endpoint so per-installation
  # usage stays observable on the dashboard between rate-limit events.
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

      client = project.client
      snapshot = client.rate_limit_snapshot
      remaining = snapshot[:remaining]
      record_rate_limit_usage(project, snapshot)

      low = remaining < threshold

      if low
        logger.warn(
          message: "rate_limit.budget_low",
          project_id: project_id,
          remaining: remaining,
          threshold: threshold,
          auth_source: project.github_auth_source
        )
      end

      { rate_limit_remaining: remaining, rate_limit_low: low }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end

    private

    # Best-effort: persist the sampled quota so the dashboard can show
    # per-installation / per-token usage. Failures here must not mask the
    # real probe result returned to the workflow.
    def record_rate_limit_usage(project, snapshot)
      return if snapshot[:remaining].nil?

      GithubHealthState.current(endpoint: project.github_health_endpoint)
        .record_rate_limit_usage!(
          remaining: snapshot[:remaining],
          limit: snapshot[:limit],
          reset_at: snapshot[:reset_at]
        )
    rescue => e
      logger.warn(
        message: "rate_limit.usage_record_failed",
        project_id: project.id,
        auth_source: project.github_auth_source,
        error: e.message
      )
    end
  end
end
