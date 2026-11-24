# frozen_string_literal: true

module AgentRuns
  # Retries the bounded authority carried by one manually-started issue implementation.
  # @spec MANUAL-RUN-RETRY-010 AGENT-RETRY-019 EAGER-QUEUE-019
  class ManualIssueCreatePrRetryPolicy
    ACTIVE_ISSUE_CONSTRAINT = "idx_agent_runs_unique_active_issue"

    Assessment = Data.define(:eligible?, :reason, :attempt, :existing_run)

    class << self
      def manual_issue_create_pr_run?(agent_run)
        agent_run.manual? && agent_run.create_pr_goal? && agent_run.issue_id.present? &&
          agent_run.source_pull_request_number.blank?
      end
    end

    def assess(agent_run, retry_number: next_attempt(agent_run))
      return Assessment.new(false, :retry_budget_exhausted, retry_number, nil) if retry_number > maximum_attempts
      return Assessment.new(false, :not_manual_issue_create_pr, retry_number, nil) unless self.class.manual_issue_create_pr_run?(agent_run)
      return Assessment.new(false, :not_failed, retry_number, nil) unless agent_run.status.in?(AgentRun::FAILURE_STATUSES)
      return Assessment.new(false, :execution_budget_exhausted, retry_number, nil) if execution_budget_exhausted?(agent_run)
      return Assessment.new(false, :rate_limit_recovery_owned, retry_number, nil) if agent_run.recoverable_rate_limited?
      if agent_run.implementation_work_produced? || agent_run.unpublished_result_commit_sha.present?
        return Assessment.new(false, :implementation_work_produced, retry_number, nil)
      end
      return Assessment.new(false, :project_retry_disabled, retry_number, nil) unless agent_run.project.retry_failed_manual_runs?
      return Assessment.new(false, :project_or_issue_paused, retry_number, nil) if paused?(agent_run)
      return Assessment.new(false, :issue_not_eligible, retry_number, nil) unless issue_eligible?(agent_run)

      existing_run = existing_active_run_for(agent_run)
      return Assessment.new(false, :existing_active_run, retry_number, existing_run) if existing_run

      Assessment.new(true, :eligible, retry_number, nil)
    end

    def next_attempt(agent_run) = agent_run.manual_retry_attempt + 1
    def maximum_attempts = AgentRun::MAX_MANUAL_RETRY_ATTEMPTS
    def attempt_class = AgentRun
    def duplicate_claim_conflict?(error) = constraint_name(error) == ACTIVE_ISSUE_CONSTRAINT
    def conflict_reason(_error) = :existing_active_run

    # The active-owner check must run while holding the source issue because
    # the database index permits different goals and excludes parked
    # rate-limited runs.
    def with_claim_lock(agent_run)
      agent_run.issue.with_lock { yield }
    end

    def build_successor!(original, attempt)
      original.issue.with_lock do
        original.reload
        next unless assess(original, retry_number: attempt).eligible?

        create_successor!(original, attempt)
      end
    end

    def create_successor!(original, attempt)
      AgentRun.create!(
        project: original.project, issue: original.issue, initiating_user: original.initiating_user,
        runner: original.runner, agent_type: original.agent_type, custom_prompt: original.custom_prompt,
        plan_doc_source: original.plan_doc_source, goal: original.goal, priority_tier: original.priority_tier,
        review_depth_snapshot: original.review_depth_snapshot,
        **original.maintenance_context_attributes,
        source_pull_request_number: original.source_pull_request_number,
        trigger_type: "manual", status: "queued",
        external_metadata: original.external_metadata.merge(
          AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY => attempt,
          AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY => original.id,
          "manual_recovery_authorization" => true
        )
      )
    end
    private :create_successor!

    def record_claim!(agent_run, successor:, decision_point:, retry_number:)
      agent_run.retry!(decision_point:, signals: retry_signals(retry_number),
        result: { new_agent_run_id: successor.id, reason: "retry_claimed" })
    end

    def record_skip!(agent_run, reason:, decision_point:, retry_number:)
      OrchestrationDecision.record(project: agent_run.project, issue: agent_run.issue, agent_run:,
        decision_point:, action: "manual_issue_create_pr_failed_run_retry", status: "noop",
        signals: retry_signals(retry_number).merge(reason: reason.to_s), result: { reason: reason.to_s })
    end

    def handle_ineligible!(agent_run, assessment, decision_point:)
      return unless assessment.reason == :existing_active_run
      return unless assessment.existing_run.goal == agent_run.goal

      agent_run.retry!(decision_point:, signals: retry_signals(assessment.attempt),
        result: { existing_agent_run_id: assessment.existing_run.id, reason: "existing_active_run" })
      RetryableAttempts::RetryAttempt::Result.new(:existing_active_run, assessment.reason, agent_run, assessment.existing_run)
    end

    def handle_duplicate_claim!(agent_run, retry_number, error:, decision_point:)
      existing_run = existing_active_run_for(agent_run)
      raise error unless existing_run

      handle_ineligible!(agent_run, Assessment.new(false, :existing_active_run, retry_number, existing_run), decision_point:)
    end

    private

    def execution_budget_exhausted?(agent_run)
      agent_run.status == "token_budget_exceeded" || agent_run.guardrail_violation_type.present?
    end

    def paused?(agent_run)
      agent_run.project.paused? || agent_run.project.quality_paused? || agent_run.issue.paused?
    end

    def issue_eligible?(agent_run)
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_for_dequeue?(
        agent_run.project, agent_run.issue_id, excluding_run_id: agent_run.id
      )
    end

    def existing_active_run_for(agent_run)
      AgentRun.where(project: agent_run.project, issue: agent_run.issue,
        status: AgentRun::DEDUP_BLOCKING_STATUSES).where.not(id: agent_run.id).first
    end

    def constraint_name(error)
      error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
    end

    def retry_signals(attempt)
      { attempt:, max_attempts: maximum_attempts, source: "manual_issue_authorization" }
    end
  end
end
