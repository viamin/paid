# frozen_string_literal: true

# Claims a replacement for a timed-out create_issue run. Timeout admission,
# operation identity, and successor construction belong to the policy; the
# shared retry service owns the locked claim and durable skip mechanics.
# @spec AGENT-RETRY-014 AGENT-RETRY-015
class RetryTimedOutIssueGoalJob < ApplicationJob
  queue_as :default

  MAX_RETRIES = AgentRuns::TimeoutIssueGoalRetryPolicy::MAX_RETRIES

  def perform(agent_run_id)
    result = retry_attempt.claim(attempt_id: agent_run_id)
    return unless result.dispatch?

    log_retry_result(result)
    ProcessRunQueueJob.perform_later
  end

  private

  def log_retry_result(result)
    attributes = {
      original_agent_run_id: result.attempt.id,
      issue_id: result.attempt.issue_id,
      project_id: result.attempt.project_id
    }

    if result.outcome == :existing_active_run
      Rails.logger.info(message: "agent_execution.issue_goal_auto_retry_skipped_existing_run",
        **attributes, existing_agent_run_id: result.successor.id)
    else
      Rails.logger.info(message: "agent_execution.issue_goal_auto_retry",
        **attributes, new_agent_run_id: result.successor.id)
    end
  end

  def retry_attempt
    RetryableAttempts::RetryAttempt.new(policy: retry_policy, decision_point: "timeout_auto_retry")
  end

  def retry_policy
    @retry_policy ||= AgentRuns::TimeoutIssueGoalRetryPolicy.new
  end
end
