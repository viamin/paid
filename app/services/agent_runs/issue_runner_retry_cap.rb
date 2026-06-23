# frozen_string_literal: true

module AgentRuns
  # Enforces the per-issue per-provider retry cap (#2513).
  #
  # After a single provider fails the configured cap times for one issue (across
  # prior runs, counting only real execution failures — error/timeout/
  # infinite_loop/preflight_timeout), it is excluded from scheduling for that
  # issue so the remaining providers get a chance instead of burning more retries
  # on a provider that keeps failing. When every available provider has hit the
  # cap the issue is abandoned entirely (see Issue#abandon_due_to_runner_retry_cap!).
  #
  # Failure counts are derived from {IssueRunnerFailureHistory} and are goal-scoped,
  # so a create_pr cap is independent of analyze_issue retries for the same issue.
  class IssueRunnerRetryCap
    # Larger inspection window than the ordering history so a provider that has
    # steadily failed across many runs still trips the cap even when other
    # providers' failures would otherwise scroll it out of a smaller window.
    INSPECTION_WINDOW = 50

    def self.capped_runner_keys(project:, issue:, goal:, cap:, exclude_run_id: nil)
      new(project: project, issue: issue, goal: goal, cap: cap, exclude_run_id: exclude_run_id)
        .capped_runner_keys
    end

    def self.cap_reached?(project:, issue:, goal:, runner_key:, cap:, exclude_run_id: nil)
      new(project: project, issue: issue, goal: goal, cap: cap, exclude_run_id: exclude_run_id)
        .cap_reached?(runner_key)
    end

    def initialize(project:, issue:, goal:, cap:, exclude_run_id: nil)
      @project = project
      @issue = issue
      @goal = goal
      @cap = cap
      @exclude_run_id = exclude_run_id
    end

    # Returns the set of canonical runner keys (e.g. "claude", "codex") that have
    # reached the per-issue retry cap.
    def capped_runner_keys
      return Set.new unless enforceable?

      failure_counts.each_with_object(Set.new) do |(runner_key, count), capped|
        capped << runner_key if count >= cap
      end
    end

    # True when a single canonical runner key has reached the cap.
    def cap_reached?(runner_key)
      return false unless enforceable?
      return false if runner_key.blank?

      failure_counts.fetch(runner_key.to_s, 0) >= cap
    end

    private

    attr_reader :project, :issue, :goal, :cap, :exclude_run_id

    def enforceable?
      issue.present? && cap.present? && cap.positive?
    end

    def failure_counts
      @failure_counts ||= AgentRuns::IssueRunnerFailureHistory.for_issue(
        project: project,
        issue: issue,
        goal: goal,
        exclude_run_id: exclude_run_id,
        max_prior_runs: INSPECTION_WINDOW
      )
    end
  end
end
