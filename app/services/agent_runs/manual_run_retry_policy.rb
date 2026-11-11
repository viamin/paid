# frozen_string_literal: true

module AgentRuns
  # Owns eligibility and successor construction for issue-less manual retries.
  # The generic retry mechanism deliberately does not know these use-case rules.
  # @spec MANUAL-RUN-RETRY-002 MANUAL-RUN-RETRY-003 MANUAL-RUN-RETRY-004 MANUAL-RUN-RETRY-006 MANUAL-RUN-RETRY-009
  class ManualRunRetryPolicy
    ACTIVE_LID_PLANNING_STATUSES = %w[queued running paused rate_limited].freeze
    ACTIVE_LID_PLANNING_CONSTRAINT = "idx_agent_runs_unique_active_lid_planning"

    Assessment = Data.define(:eligible?, :reason, :attempt)

    def assess(agent_run, attempt: next_attempt(agent_run))
      return Assessment.new(false, :retry_budget_exhausted, attempt) if attempt > AgentRun::MAX_MANUAL_RETRY_ATTEMPTS
      return Assessment.new(false, :not_manual, attempt) unless agent_run.manual?
      return Assessment.new(false, :bootstrap_readiness_goal, attempt) if agent_run.bootstrap_readiness_goal?
      return Assessment.new(false, :layered_verification_goal, attempt) if agent_run.layered_verification_goal?
      return Assessment.new(false, :issue_attached, attempt) if agent_run.issue_id.present?
      return Assessment.new(false, :source_pr_attached, attempt) if agent_run.source_pull_request_number.present?
      return Assessment.new(false, :not_failed, attempt) unless agent_run.status.in?(AgentRun::FAILURE_STATUSES)
      return Assessment.new(false, :rate_limit_recovery_owned, attempt) if agent_run.recoverable_rate_limited?
      return Assessment.new(false, :project_retry_disabled, attempt) unless agent_run.project&.retry_failed_manual_runs?
      return Assessment.new(false, :observable_work_produced, attempt) unless agent_run.no_observable_work?
      return Assessment.new(false, :active_lid_planning_run, attempt) if active_lid_planning_run?(agent_run)

      Assessment.new(true, :eligible, attempt)
    end

    def next_attempt(agent_run)
      agent_run.manual_retry_attempt + 1
    end

    def build_successor!(original, attempt)
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
          AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY => attempt,
          AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY => original.id
        )
      )
    end

    def duplicate_active_run_conflict?(error)
      error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == ACTIVE_LID_PLANNING_CONSTRAINT
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
