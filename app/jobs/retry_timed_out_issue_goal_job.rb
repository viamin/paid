# frozen_string_literal: true

# Claims a replacement for a timed-out create_issue run. Timeout admission,
# operation identity, and successor construction belong to the policy; the
# shared RetryAttempt service owns the locked claim and durable skip mechanics.
# @spec AGENT-RETRY-014 AGENT-RETRY-015
class RetryTimedOutIssueGoalJob < ApplicationJob
  queue_as :default

  MAX_RETRIES = AgentRuns::TimeoutIssueGoalRetryPolicy::MAX_RETRIES

  def perform(agent_run_id)
    result = retry_attempt.claim(agent_run_id: agent_run_id)
    return unless result.dispatch?

    log_retry_result(result)

    ProcessRunQueueJob.perform_later
  end

  private

  def log_retry_result(result)
    if result.outcome == :existing_active_run
      Rails.logger.info(
        message: "agent_execution.issue_goal_auto_retry_skipped_existing_run",
        original_agent_run_id: result.agent_run.id,
        existing_agent_run_id: result.successor.id,
        issue_id: result.agent_run.issue_id,
        project_id: result.agent_run.project_id
      )
    else
      Rails.logger.info(
        message: "agent_execution.issue_goal_auto_retry",
        original_agent_run_id: result.agent_run.id,
        new_agent_run_id: result.successor.id,
        issue_id: result.agent_run.issue_id,
        project_id: result.agent_run.project_id
      )
    end
  end

  def retry_attempt
    AgentRuns::RetryAttempt.new(
      policy: AgentRuns::TimeoutIssueGoalRetryPolicy.new,
      decision_point: "timeout_auto_retry"
    )
  end
end
