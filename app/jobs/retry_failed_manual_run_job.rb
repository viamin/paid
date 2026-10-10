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

  def perform(agent_run_id, attempt) # @spec MANUAL-RUN-RETRY-001 MANUAL-RUN-RETRY-005
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    new_run = AgentRun.transaction do
      locked_run = AgentRun.lock.find_by(id: agent_run.id)
      next unless locked_run && eligible_for_retry?(locked_run, attempt)

      locked_run.retry!(
        decision_point: "manual_failed_run_auto_retry",
        signals: { attempt: attempt, max_attempts: AgentRun::MAX_MANUAL_RETRY_ATTEMPTS },
        result: {}
      )
      create_retry_run(locked_run, attempt)
    end
    return unless new_run

    Rails.logger.info(
      message: "agent_execution.manual_failed_run_auto_retry",
      original_agent_run_id: agent_run.id,
      new_agent_run_id: new_run.id,
      project_id: agent_run.project_id,
      goal: agent_run.goal,
      attempt: attempt
    )

    ProcessRunQueueJob.perform_later
  end

  private

  # Re-checks eligibility under the row lock: state may have changed since
  # the activity scheduled this job (the project toggle flipped off, the run
  # was already retried, or an operator manually intervened).
  def eligible_for_retry?(agent_run, attempt)
    attempt <= AgentRun::MAX_MANUAL_RETRY_ATTEMPTS &&
      agent_run.manual? &&
      agent_run.issue_id.nil? &&
      agent_run.source_pull_request_number.nil? &&
      agent_run.status.in?(AgentRun::FAILURE_STATUSES) &&
      !agent_run.recoverable_rate_limited? &&
      agent_run.project&.retry_failed_manual_runs? &&
      agent_run.no_observable_work?
  end

  def create_retry_run(original, attempt)
    AgentRun.create!(
      project: original.project,
      initiating_user: original.initiating_user,
      runner: original.runner,
      agent_type: original.agent_type,
      custom_prompt: original.custom_prompt,
      goal: original.goal,
      trigger_type: "manual",
      status: "queued",
      external_metadata: original.external_metadata.merge(
        AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY => attempt,
        AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY => original.id
      )
    )
  end
end
