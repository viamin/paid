# frozen_string_literal: true

module AgentRuns
  # Owns timeout-specific admission, lineage, and successor construction for
  # create_issue retries. RetryAttempt owns the locked claim mechanics.
  # @spec AGENT-RETRY-014 AGENT-RETRY-015
  class TimeoutIssueGoalRetryPolicy
    MAX_RETRIES = 3
    OPERATION_KEY = AgentRun::CREATE_ISSUE_OPERATION_KEY_METADATA_KEY
    RETRY_ATTEMPT_KEY = "create_issue_retry_attempt".freeze
    ACTIVE_ISSUE_CONSTRAINT = "idx_agent_runs_unique_active_issue"
    ACTIVE_PR_CONSTRAINT = "idx_agent_runs_unique_active_pr"

    Assessment = Data.define(:eligible?, :reason, :attempt, :existing_run)

    def assess(agent_run, attempt: next_attempt(agent_run))
      return Assessment.new(false, :not_timeout, attempt, nil) unless agent_run.status == "timeout"
      return Assessment.new(false, :not_create_issue, attempt, nil) unless agent_run.create_issue_goal?
      return Assessment.new(false, :layered_verification_goal, attempt, nil) if agent_run.layered_verification_goal?
      return Assessment.new(false, :retry_limit_reached, attempt, nil) if attempt > MAX_RETRIES

      existing_run = existing_active_run_for(agent_run)
      return Assessment.new(false, :existing_active_run, attempt, existing_run) if existing_run

      Assessment.new(true, :eligible, attempt, nil)
    end

    def next_attempt(agent_run)
      return agent_run.external_metadata.fetch(RETRY_ATTEMPT_KEY, 0).to_i + 1 if agent_run.create_issue_operation_key.present?

      legacy_previous_retries(agent_run) + 1
    end

    def maximum_attempts
      MAX_RETRIES
    end

    def retry_action
      "retry"
    end

    def retry_signals(attempt)
      { previous_retries: attempt - 1, retry_attempt: attempt, max_retries: MAX_RETRIES }
    end

    def retry_result(successor, attempt)
      { new_agent_run_id: successor.id, retry_attempt: attempt }
    end

    def build_successor!(original, attempt)
      operation_key = original.create_issue_operation_key || "agent-run:#{original.id}"
      original.update!(external_metadata: original.external_metadata.merge(
        OPERATION_KEY => operation_key,
        RETRY_ATTEMPT_KEY => attempt - 1
      ))

      AgentRun.create!(
        project: original.project,
        issue: original.issue,
        initiating_user: original.initiating_user,
        runner: original.runner,
        agent_type: original.agent_type,
        custom_prompt: original.custom_prompt,
        source_pull_request_number: original.source_pull_request_number,
        goal: original.goal,
        trigger_type: "manual",
        external_metadata: original.external_metadata.merge(
          "automatic_authorization" => true,
          OPERATION_KEY => operation_key,
          RETRY_ATTEMPT_KEY => attempt
        ),
        status: "queued"
      )
    end

    def handle_ineligible!(agent_run, assessment, decision_point:)
      if assessment.reason == :retry_limit_reached
        agent_run.update!(error_message: "Auto-retry limit reached (#{MAX_RETRIES} retries)")
        record_decision(agent_run, status: "noop", attempt: assessment.attempt, result: { reason: "retry_limit_reached", retry_attempt: assessment.attempt })
        log_retry_limit_reached(agent_run, assessment.attempt)
      elsif assessment.reason == :existing_active_run
        mark_existing_run_retry!(agent_run, assessment.existing_run, assessment.attempt, decision_point)
        return RetryAttempt::Result.new(:existing_active_run, :existing_active_run, agent_run, assessment.existing_run)
      else
        return nil
      end

      RetryAttempt::Result.new(:skipped, assessment.reason, agent_run, nil)
    end

    def duplicate_active_run_conflict?(error)
      message = error.cause&.message || error.message
      message.include?(ACTIVE_ISSUE_CONSTRAINT) || message.include?(ACTIVE_PR_CONSTRAINT)
    end

    def handle_duplicate_active_run!(agent_run, attempt)
      existing_run = existing_active_run_for(agent_run)
      raise ActiveRecord::RecordNotUnique unless existing_run

      mark_existing_run_retry!(agent_run, existing_run, attempt, "timeout_auto_retry")
      RetryAttempt::Result.new(:existing_active_run, :existing_active_run, agent_run, existing_run)
    end

    private

    def legacy_previous_retries(agent_run)
      scope = if agent_run.issue_id
        agent_run.issue.agent_runs.where(goal: "create_issue")
      else
        AgentRun.where(
          project_id: agent_run.project_id,
          goal: agent_run.goal,
          issue_id: nil,
          runner: agent_run.runner,
          agent_type: agent_run.agent_type,
          custom_prompt: agent_run.custom_prompt,
          source_pull_request_number: agent_run.source_pull_request_number
        )
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

    def log_retry_limit_reached(agent_run, attempt)
      Rails.logger.info(
        message: "agent_execution.issue_goal_retry_limit_reached",
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id,
        project_id: agent_run.project_id,
        previous_retries: attempt - 1,
        max_retries: MAX_RETRIES
      )
    end

    def mark_existing_run_retry!(agent_run, existing_run, attempt, decision_point)
      agent_run.retry!(
        decision_point: decision_point,
        signals: retry_signals(attempt),
        result: { existing_agent_run_id: existing_run.id, reason: "existing_active_run", retry_attempt: attempt }
      )
    end

    def record_decision(agent_run, status:, attempt:, result:)
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "timeout_auto_retry",
        action: retry_action,
        status: status,
        signals: retry_signals(attempt),
        result: result
      )
    end
  end
end
