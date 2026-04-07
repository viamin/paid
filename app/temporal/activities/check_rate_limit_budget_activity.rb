# frozen_string_literal: true

module Activities
  # Checks whether the project's GitHub token has sufficient API rate limit
  # budget to continue running optional polling activities (PR scanning,
  # security alerts, knowledge staleness). Returns budget_ok: false when
  # the remaining budget is too low, allowing the workflow to skip
  # non-essential activities and preserve budget for the next cycle.
  class CheckRateLimitBudgetActivity < BaseActivity
    # Minimum remaining requests needed to justify running optional
    # polling activities. Below this threshold, we defer to the next cycle.
    MINIMUM_BUDGET = 100

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { budget_ok: false, project_missing: true } unless project

      client = project.github_token&.client
      return { budget_ok: false } unless client

      remaining = client.rate_limit_remaining
      budget_ok = remaining >= MINIMUM_BUDGET

      unless budget_ok
        logger.warn(
          message: "github_sync.budget_insufficient",
          project_id: project.id,
          remaining: remaining,
          threshold: MINIMUM_BUDGET
        )
      end

      { budget_ok: budget_ok, remaining: remaining }
    end
  end
end
