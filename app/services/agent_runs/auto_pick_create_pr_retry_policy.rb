# frozen_string_literal: true

module AgentRuns
  # Preserves issue-owned Auto-Pick admission while using RetryAttempt's locked
  # decision recording for a failed implementation source.
  # @spec AGENT-RETRY-015 EAGER-QUEUE-018 PARTIAL-CLOSEOUT-045
  class AutoPickCreatePrRetryPolicy
    Assessment = Data.define(:eligible?, :reason, :attempt)

    def assess(agent_run, attempt: next_attempt(agent_run))
      return Assessment.new(false, :not_auto_pick_create_pr, attempt) unless auto_pick_create_pr?(agent_run)
      return Assessment.new(false, :rate_limit_recovery_owned, attempt) if agent_run.recoverable_rate_limited?
      return Assessment.new(false, :not_failed, attempt) unless agent_run.status.in?(AgentRun::FAILURE_STATUSES)
      return Assessment.new(false, :implementation_work_produced, attempt) if implementation_work_produced?(agent_run)
      return Assessment.new(false, :retry_budget_exhausted, attempt) if retry_budget_exhausted?(agent_run, attempt)

      Assessment.new(true, :eligible, attempt)
    end

    def next_attempt(agent_run)
      agent_run.issue.consecutive_auto_pick_failure_count
    end

    def maximum_attempts
      "issue_retry_cap"
    end

    def build_successor!(agent_run, _attempt)
      Issues::EnqueueEligible.call(agent_run.issue, project: agent_run.project)
    end

    def duplicate_active_run_conflict?(_error)
      false
    end

    private

    def auto_pick_create_pr?(agent_run)
      agent_run.auto_pick? && agent_run.goal == "create_pr" && agent_run.issue_id.present?
    end

    def implementation_work_produced?(agent_run)
      agent_run.result_commit_sha.present? || !agent_run.no_observable_work?
    end

    def retry_budget_exhausted?(agent_run, attempt)
      cap = agent_run.project.effective_max_issue_runner_failures
      cap.present? && cap.positive? && attempt >= cap
    end
  end
end
