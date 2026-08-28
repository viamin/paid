# frozen_string_literal: true

module Reviews
  # Query object over a pull request's automatic review-goal run history.
  # Extracted from ScanPaidPrsActivity so the awaiting_approval escalation
  # re-validation reads the same run history — with the same retry-cycle
  # semantics — as the scan that queued the escalation.
  class AutomaticRunHistory
    # A finished run in any of these states ended without producing a usable
    # review. Shared by the scan's retry logic and the blocking-review
    # completion gate.
    RETRYABLE_FAILURE_STATUSES = (AgentRun::FAILURE_STATUSES + %w[no_output]).freeze

    # The most recent finished, non-retried automatic review-goal run in the
    # PR's current review cycle, newest first. +progress_state+ is optional:
    # when nil, the reset boundary falls back to the issue's persisted
    # review_goal_retry_reset_at only.
    def self.latest_finished(project:, issue:, progress_state: nil)
      attempted_since_retry_reset(project:, issue:, progress_state:)
        .finished
        .order(Arel.sql("#{PullRequests::ProgressState::RUN_TIMESTAMP_SQL} DESC, created_at DESC, id DESC"))
        .first
    end

    def self.attempted_since_retry_reset(project:, issue:, progress_state: nil)
      scope = attempted(project:, issue:)
      reset_at = [ issue.review_goal_retry_reset_at, progress_state&.last_meaningful_progress_at ].compact.max
      return scope unless reset_at

      scope.where(cycle_boundary.gt(reset_at))
    end

    def self.attempted(project:, issue:)
      automatic_review_runs(project:, issue:).where.not(status: "retried")
    end

    # Arel expression for a run's earliest known attempt timestamp. Used to
    # keep runs queued before a restart in the old review cycle even if they
    # start or finish afterward.
    def self.cycle_boundary
      agent_runs = AgentRun.arel_table
      Arel::Nodes::Case.new
        .when(agent_runs[:started_at].eq(nil))
        .then(agent_runs[:created_at])
        .else(Arel::Nodes::NamedFunction.new("LEAST", [
          agent_runs[:started_at],
          agent_runs[:created_at]
        ]))
    end

    def self.automatic_review_runs(project:, issue:)
      all_review_runs(project:, issue:).where(trigger_type: "automatic")
    end
    private_class_method :automatic_review_runs

    def self.all_review_runs(project:, issue:)
      runs_for_current_cycle(
        AgentRun.pr_history_scope(project:, issue:, pr_number: issue.github_number).where(goal: "review"),
        issue
      )
    end
    private_class_method :all_review_runs

    def self.runs_for_current_cycle(runs, issue)
      return runs unless issue.pr_review_phase == "restarted"

      reset_at = issue.review_goal_retry_reset_at
      return runs unless reset_at

      runs.where(cycle_boundary.gt(reset_at))
    end
    private_class_method :runs_for_current_cycle
  end
end
