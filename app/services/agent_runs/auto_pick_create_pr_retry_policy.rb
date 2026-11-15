# frozen_string_literal: true

module AgentRuns
  # Preserves issue-owned Auto-Pick admission while using the shared locked
  # decision recording for a failed implementation source.
  # @spec AGENT-RETRY-017 EAGER-QUEUE-018 PARTIAL-CLOSEOUT-045
  class AutoPickCreatePrRetryPolicy
    Assessment = Data.define(:eligible?, :reason, :attempt)

    def assess(agent_run, retry_number: next_attempt(agent_run))
      return Assessment.new(false, :not_auto_pick_create_pr, retry_number) unless auto_pick_create_pr?(agent_run)
      return Assessment.new(false, :rate_limit_recovery_owned, retry_number) if agent_run.recoverable_rate_limited?
      return Assessment.new(false, :not_failed, retry_number) unless agent_run.status.in?(AgentRun::FAILURE_STATUSES)
      return Assessment.new(false, :implementation_work_produced, retry_number) if implementation_work_produced?(agent_run)
      return Assessment.new(false, :retry_budget_exhausted, retry_number) if retry_budget_exhausted?(agent_run, retry_number)

      Assessment.new(true, :eligible, retry_number)
    end

    def next_attempt(agent_run)
      agent_run.issue.consecutive_auto_pick_failure_count
    end

    def maximum_attempts
      "issue_retry_cap"
    end

    def attempt_class
      AgentRun
    end

    def build_successor!(agent_run, _retry_number)
      Issues::EnqueueEligible.call(agent_run.issue, project: agent_run.project)
    end

    def duplicate_claim_conflict?(_error)
      false
    end

    def conflict_reason(_error)
      :already_claimed
    end

    def record_claim!(agent_run, successor:, decision_point:, retry_number:)
      agent_run.retry!(
        decision_point:,
        signals: retry_signals(retry_number),
        result: { new_agent_run_id: successor.id, reason: "retry_claimed" }
      )
    end

    def record_skip!(agent_run, reason:, decision_point:, retry_number:)
      OrchestrationDecision.record(
        project: agent_run.project,
        agent_run:,
        decision_point:,
        action: "auto_pick_create_pr_failed_run_retry",
        status: "noop",
        signals: retry_signals(retry_number).merge(reason: reason.to_s),
        result: { reason: reason.to_s }
      )
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

    def retry_signals(attempt)
      { attempt:, max_attempts: maximum_attempts }
    end
  end
end
