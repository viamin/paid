# frozen_string_literal: true

module AgentRuns
  # Owns timeout-specific admission, lineage, and successor construction for
  # create_issue retries. RetryableAttempts::RetryAttempt owns locked claims.
  # @spec AGENT-RETRY-014 AGENT-RETRY-015
  class TimeoutIssueGoalRetryPolicy
    MAX_RETRIES = 3
    OPERATION_KEY = AgentRun::CREATE_ISSUE_OPERATION_KEY_METADATA_KEY
    RETRY_ATTEMPT_KEY = "create_issue_retry_attempt".freeze
    ACTIVE_ISSUE_CONSTRAINT = "idx_agent_runs_unique_active_issue"
    ACTIVE_PR_CONSTRAINT = "idx_agent_runs_unique_active_pr"

    Assessment = Data.define(:eligible?, :reason, :attempt, :existing_run)

    def assess(agent_run, retry_number: next_attempt(agent_run))
      return Assessment.new(false, :not_timeout, retry_number, nil) unless agent_run.status == "timeout"
      return Assessment.new(false, :not_create_issue, retry_number, nil) unless agent_run.create_issue_goal?
      return Assessment.new(false, :layered_verification_goal, retry_number, nil) if agent_run.layered_verification_goal?
      return Assessment.new(false, :retry_limit_reached, retry_number, nil) if retry_number > MAX_RETRIES

      existing_run = existing_active_run_for(agent_run)
      return Assessment.new(false, :existing_active_run, retry_number, existing_run) if existing_run

      Assessment.new(true, :eligible, retry_number, nil)
    end

    def next_attempt(agent_run)
      return agent_run.external_metadata.fetch(RETRY_ATTEMPT_KEY, 0).to_i + 1 if agent_run.create_issue_operation_key.present?

      legacy_previous_retries(agent_run) + 1
    end

    def maximum_attempts = MAX_RETRIES
    def attempt_class = AgentRun
    def duplicate_claim_conflict?(error) = active_run_conflict?(error)
    def conflict_reason(_error) = :existing_active_run

    def build_successor!(original, retry_number)
      operation_key = original.create_issue_operation_key || "agent-run:#{original.id}"
      original.update!(external_metadata: original.external_metadata.merge(
        OPERATION_KEY => operation_key,
        RETRY_ATTEMPT_KEY => retry_number - 1
      ))
      AgentRun.create!(successor_attributes(original, operation_key, retry_number))
    end

    def record_claim!(agent_run, successor:, decision_point:, retry_number:)
      agent_run.retry!(decision_point:, signals: retry_signals(retry_number),
        result: { new_agent_run_id: successor.id, retry_attempt: retry_number })
    end

    def record_skip!(agent_run, reason:, decision_point:, retry_number:)
      if reason == :retry_limit_reached
        record_exhaustion!(agent_run, retry_number)
      else
        record_decision(agent_run, decision_point:, retry_number:, reason:)
      end
    end

    def handle_ineligible!(agent_run, assessment, decision_point:)
      return unless assessment.reason == :existing_active_run

      mark_existing_run_retry!(agent_run, assessment.existing_run, assessment.attempt, decision_point)
      RetryableAttempts::RetryAttempt::Result.new(:existing_active_run, assessment.reason, agent_run, assessment.existing_run)
    end

    def handle_duplicate_claim!(agent_run, retry_number, error:, decision_point:)
      existing_run = existing_active_run_for(agent_run)
      raise error unless existing_run

      mark_existing_run_retry!(agent_run, existing_run, retry_number, decision_point)
      RetryableAttempts::RetryAttempt::Result.new(:existing_active_run, :existing_active_run, agent_run, existing_run)
    end

    private

    def successor_attributes(original, operation_key, retry_number)
      {
        project: original.project, issue: original.issue, initiating_user: original.initiating_user,
        runner: original.runner, agent_type: original.agent_type, custom_prompt: original.custom_prompt,
        source_pull_request_number: original.source_pull_request_number, goal: original.goal,
        trigger_type: "manual", status: "queued",
        external_metadata: original.external_metadata.merge(
          "automatic_authorization" => true, OPERATION_KEY => operation_key, RETRY_ATTEMPT_KEY => retry_number
        )
      }
    end

    def legacy_previous_retries(agent_run)
      scope = if agent_run.issue_id
        agent_run.issue.agent_runs.where(goal: "create_issue")
      else
        AgentRun.where(project_id: agent_run.project_id, goal: agent_run.goal, issue_id: nil,
          runner: agent_run.runner, agent_type: agent_run.agent_type, custom_prompt: agent_run.custom_prompt,
          source_pull_request_number: agent_run.source_pull_request_number)
      end
      scope.where(status: %w[timeout retried]).where.not(id: agent_run.id).count
    end

    def existing_active_run_for(agent_run)
      scope = AgentRun.where(project_id: agent_run.project_id, goal: agent_run.goal, status: AgentRun::UNFINISHED_STATUSES)
        .where.not(id: agent_run.id)
      existing_run = scope.find_by(issue_id: agent_run.issue_id) if agent_run.issue_id.present?
      return existing_run if existing_run

      scope.find_by(source_pull_request_number: agent_run.source_pull_request_number) if agent_run.source_pull_request_number.present?
    end

    def active_run_conflict?(error)
      message = error.cause&.message || error.message
      message.include?(ACTIVE_ISSUE_CONSTRAINT) || message.include?(ACTIVE_PR_CONSTRAINT)
    end

    def retry_signals(retry_number)
      { previous_retries: retry_number - 1, retry_attempt: retry_number, max_retries: MAX_RETRIES }
    end

    def mark_existing_run_retry!(agent_run, existing_run, retry_number, decision_point)
      agent_run.retry!(decision_point:, signals: retry_signals(retry_number),
        result: { existing_agent_run_id: existing_run.id, reason: "existing_active_run", retry_attempt: retry_number })
    end

    def record_exhaustion!(agent_run, retry_number)
      agent_run.update!(error_message: "Auto-retry limit reached (#{MAX_RETRIES} retries)")
      record_decision(agent_run, decision_point: "timeout_auto_retry", retry_number:, reason: :retry_limit_reached)
      Rails.logger.info(message: "agent_execution.issue_goal_retry_limit_reached",
        agent_run_id: agent_run.id, issue_id: agent_run.issue_id, project_id: agent_run.project_id,
        previous_retries: retry_number - 1, max_retries: MAX_RETRIES)
    end

    def record_decision(agent_run, decision_point:, retry_number:, reason:)
      OrchestrationDecision.record(project: agent_run.project, issue: agent_run.issue, agent_run:,
        decision_point:, action: "retry", status: "noop",
        signals: retry_signals(retry_number).merge(reason: reason.to_s),
        result: { reason: reason.to_s, retry_attempt: retry_number })
    end
  end
end
