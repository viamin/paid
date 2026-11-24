# frozen_string_literal: true

# Claims one bounded successor of a failed manual issue implementation.
# @spec MANUAL-RUN-RETRY-010 AGENT-RETRY-019 EAGER-QUEUE-019
class RetryFailedManualIssueCreatePrJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "retry_failed_manual_issue_create_pr_#{arguments.first}" }
  )

  def perform(agent_run_id, attempt)
    result = retry_attempt.claim(attempt_id: agent_run_id, retry_number: attempt)
    return unless result.claimed?

    Rails.logger.info(message: "agent_execution.manual_issue_create_pr_retry_claimed",
      original_agent_run_id: result.attempt.id, new_agent_run_id: result.successor.id,
      project_id: result.attempt.project_id, issue_id: result.attempt.issue_id, attempt:)
    ProcessRunQueueJob.perform_later
  end

  private

  def retry_attempt
    RetryableAttempts::RetryAttempt.new(
      policy: AgentRuns::ManualIssueCreatePrRetryPolicy.new,
      decision_point: "manual_issue_create_pr_failed_run_retry"
    )
  end
end
