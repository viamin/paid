# frozen_string_literal: true

# Automatically retries a failed manual agent run that has no issue or PR
# attachment (create_feature, create_issue, lid_planning, or issue-less
# create_pr). Every other recovery path in Paid is issue-driven, so without
# this job a transient dispatch-time failure (e.g. runner/provider
# exhaustion) on one of these runs is only discoverable by browsing the
# agent runs page (#4222).
#
# Mints a new queued AgentRun (mirroring RetryTimedOutIssueGoalJob) rather
# than re-running the original in place, and marks the original "retried"
# so it is never mistaken for a second active attempt. Scheduled from
# MarkAgentRunFailedActivity with exponential backoff, bounded by
# AgentRun::MAX_MANUAL_RETRY_ATTEMPTS.
# @spec MANUAL-RUN-RETRY-001
class RetryFailedManualRunJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  RETRY_BASE_DELAY = 30.seconds
  RETRY_MAX_DELAY = 5.minutes

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "retry_failed_manual_run_#{arguments.first}" }
  )

  def self.retry_delay(attempt)
    [ RETRY_BASE_DELAY * (2**(attempt - 1)), RETRY_MAX_DELAY ].min
  end

  def perform(agent_run_id, attempt) # @spec MANUAL-RUN-RETRY-001 MANUAL-RUN-RETRY-005 MANUAL-RUN-RETRY-008 MANUAL-RUN-RETRY-009
    result = retry_attempt.claim(agent_run_id: agent_run_id, attempt: attempt)
    return unless result.claimed?

    Rails.logger.info(
      message: "agent_execution.manual_failed_run_auto_retry",
      original_agent_run_id: result.agent_run.id,
      new_agent_run_id: result.successor.id,
      project_id: result.agent_run.project_id,
      goal: result.agent_run.goal,
      attempt: attempt
    )

    ProcessRunQueueJob.perform_later
  end

  private

  def retry_attempt
    AgentRuns::RetryAttempt.new(
      policy: AgentRuns::ManualRunRetryPolicy.new,
      decision_point: "manual_failed_run_auto_retry"
    )
  end
end
