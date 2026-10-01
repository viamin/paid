# frozen_string_literal: true

module AgentRuns
  # Counts consecutive no-tier dispatch failures for an issue and goal. Unlike
  # IssueRunnerFailureHistory, these failures occur before a runner attempt and
  # describe infeasible configuration rather than runner execution quality.
  # @spec RUNNER-FALLBACK-012
  class IssueDispatchFailureHistory
    MAX_PRIOR_RUNS = 50
    NO_TIER_CAPABLE_RUNNER_PREFIX = "No runner supports tier "

    class << self
      def for_issue(project:, issue:, goal:, exclude_run_id: nil, max_prior_runs: MAX_PRIOR_RUNS)
        new(
          project: project,
          issue: issue,
          goal: goal,
          exclude_run_id: exclude_run_id,
          max_prior_runs: max_prior_runs
        ).consecutive_failures
      end
    end

    def initialize(project:, issue:, goal:, exclude_run_id: nil, max_prior_runs: MAX_PRIOR_RUNS)
      @project = project
      @issue = issue
      @goal = goal
      @exclude_run_id = exclude_run_id
      @max_prior_runs = max_prior_runs
    end

    def consecutive_failures
      count = 0
      prior_runs.each do |run|
        return count if run.runners_attempted.any?

        count += 1 if no_tier_capable_runner_failure?(run)
      end

      count
    end

    private

    attr_reader :project, :issue, :goal, :exclude_run_id, :max_prior_runs

    def prior_runs
      scope = AgentRun.where(project: project, issue: issue, goal: goal)
      scope = scope.where.not(id: exclude_run_id) if exclude_run_id
      scope.order(created_at: :desc).limit(max_prior_runs)
    end

    def no_tier_capable_runner_failure?(run)
      run.error_message.to_s.start_with?(NO_TIER_CAPABLE_RUNNER_PREFIX)
    end
  end
end
