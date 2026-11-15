# frozen_string_literal: true

module AgentRuns
  # Owns eligibility and successor construction for issue-less manual retries.
  # The shared retry mechanism (Retries::Attempt) deliberately does not know
  # these use-case rules.
  # @spec MANUAL-RUN-RETRY-002 MANUAL-RUN-RETRY-003 MANUAL-RUN-RETRY-004 MANUAL-RUN-RETRY-006 MANUAL-RUN-RETRY-009
  # @spec AGENT-RETRY-015
  class ManualRunRetryPolicy
    ACTIVE_LID_PLANNING_STATUSES = %w[queued running paused rate_limited].freeze
    ACTIVE_LID_PLANNING_CONSTRAINT = "idx_agent_runs_unique_active_lid_planning"
    DECISION_ACTION = "manual_failed_run_auto_retry"

    def assess(agent_run, attempt_number: next_attempt_number(agent_run))
      return Retries::Assessment.new(false, :retry_budget_exhausted, attempt_number) if attempt_number > AgentRun::MAX_MANUAL_RETRY_ATTEMPTS
      return Retries::Assessment.new(false, :not_manual, attempt_number) unless agent_run.manual?
      return Retries::Assessment.new(false, :bootstrap_readiness_goal, attempt_number) if agent_run.bootstrap_readiness_goal?
      return Retries::Assessment.new(false, :layered_verification_goal, attempt_number) if agent_run.layered_verification_goal?
      return Retries::Assessment.new(false, :issue_attached, attempt_number) if agent_run.issue_id.present?
      return Retries::Assessment.new(false, :source_pr_attached, attempt_number) if agent_run.source_pull_request_number.present?
      return Retries::Assessment.new(false, :not_failed, attempt_number) unless agent_run.status.in?(AgentRun::FAILURE_STATUSES)
      return Retries::Assessment.new(false, :rate_limit_recovery_owned, attempt_number) if agent_run.recoverable_rate_limited?
      return Retries::Assessment.new(false, :project_retry_disabled, attempt_number) unless agent_run.project&.retry_failed_manual_runs?
      return Retries::Assessment.new(false, :observable_work_produced, attempt_number) unless agent_run.no_observable_work?
      return Retries::Assessment.new(false, :active_lid_planning_run, attempt_number) if active_lid_planning_run?(agent_run)

      Retries::Assessment.new(true, :eligible, attempt_number)
    end

    def next_attempt_number(agent_run)
      agent_run.manual_retry_attempt + 1
    end

    def maximum_attempts
      AgentRun::MAX_MANUAL_RETRY_ATTEMPTS
    end

    def claim_transaction(&block)
      AgentRun.transaction(&block)
    end

    def lock_source(id)
      AgentRun.lock.find_by(id: id)
    end

    def find_source(id)
      AgentRun.find_by(id: id)
    end

    def admission_reason(_agent_run)
      nil
    end

    def build_successor!(original, attempt_number)
      AgentRun.create!(
        project: original.project,
        initiating_user: original.initiating_user,
        runner: original.runner,
        agent_type: original.agent_type,
        custom_prompt: original.custom_prompt,
        plan_doc_source: original.plan_doc_source,
        goal: original.goal,
        priority_tier: original.priority_tier,
        trigger_type: "manual",
        status: "queued",
        external_metadata: original.external_metadata.merge(
          AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY => attempt_number,
          AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY => original.id
        )
      )
    end

    def duplicate_claim_conflict?(error)
      error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == ACTIVE_LID_PLANNING_CONSTRAINT
    end

    def duplicate_claim_conflict_reason(_error)
      :active_lid_planning_run
    end

    # @spec AGENT-RETRY-004
    def record_claim!(agent_run, successor:, decision_point:, signals:)
      agent_run.retry!(decision_point: decision_point, signals: signals, result: { new_agent_run_id: successor.id, reason: "retry_claimed" })
    end

    # @spec AGENT-RETRY-004
    def record_skip!(agent_run, reason:, decision_point:, signals:)
      OrchestrationDecision.record(
        project: agent_run.project,
        agent_run: agent_run,
        decision_point: decision_point,
        action: DECISION_ACTION,
        status: "noop",
        signals: signals.merge(reason: reason.to_s),
        result: { reason: reason.to_s }
      )
    end

    private

    def active_lid_planning_run?(agent_run)
      return false unless agent_run.goal == "lid_planning"

      AgentRun.where(project: agent_run.project, goal: "lid_planning", status: ACTIVE_LID_PLANNING_STATUSES)
        .where.not(id: agent_run.id)
        .exists?
    end
  end
end
