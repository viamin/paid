# frozen_string_literal: true

# Claims a failed Auto-Pick implementation source, then delegates successor
# creation to the issue's ordinary eligibility and queue-admission path.
# @spec AGENT-RETRY-015 EAGER-QUEUE-018 PARTIAL-CLOSEOUT-045
class RetryFailedAutoPickCreatePrJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "retry_failed_auto_pick_create_pr_#{arguments.first}" }
  )

  def perform(agent_run_id, attempt)
    result = retry_attempt.claim(agent_run_id: agent_run_id, attempt: attempt)
    return unless result.claimed?

    Rails.logger.info(
      message: "agent_execution.auto_pick_create_pr_retry_claimed",
      original_agent_run_id: result.agent_run.id,
      new_agent_run_id: result.successor.id,
      project_id: result.agent_run.project_id,
      issue_id: result.agent_run.issue_id,
      attempt: attempt
    )

    ProcessRunQueueJob.perform_later
  end

  private

  def retry_attempt
    AgentRuns::RetryAttempt.new(
      policy: AgentRuns::AutoPickCreatePrRetryPolicy.new,
      decision_point: "auto_pick_create_pr_failed_run_retry"
    )
  end
end
