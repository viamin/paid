# frozen_string_literal: true

# Automatically retries issue goal agent runs that have timed out.
#
# When an issue goal run times out (stuck in pending/running beyond
# the timeout threshold), this job creates a new queued run with the
# same parameters so the issue creation is retried without manual
# intervention. Respects a maximum retry count to avoid infinite loops.
#
# Enqueued from AgentRun's after_commit callback when an issue goal
# run transitions to "timeout" status.
class RetryTimedOutIssueGoalJob < ApplicationJob
  queue_as :default

  MAX_RETRIES = 3

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run
    return unless eligible_for_retry?(agent_run)

    begin
      new_run = AgentRun.transaction do
        # Lock the original run to prevent concurrent retry jobs from both
        # creating a new queued run. Re-check eligibility under the lock
        # since the status may have changed since the initial check.
        locked_run = AgentRun.lock.find_by(id: agent_run.id)
        next unless locked_run && eligible_for_retry?(locked_run)

        previous_retries = count_previous_retries(locked_run)
        if previous_retries >= MAX_RETRIES
          locked_run.update!(error_message: "Auto-retry limit reached (#{MAX_RETRIES} retries)")

          Rails.logger.info(
            message: "agent_execution.issue_goal_retry_limit_reached",
            agent_run_id: locked_run.id,
            issue_id: locked_run.issue_id,
            project_id: locked_run.project_id,
            previous_retries: previous_retries,
            max_retries: MAX_RETRIES
          )
          next
        end

        created = AgentRun.create!(
          project: locked_run.project,
          issue: locked_run.issue,
          provider: locked_run.provider,
          agent_type: locked_run.agent_type,
          custom_prompt: locked_run.custom_prompt,
          source_pull_request_number: locked_run.source_pull_request_number,
          goal: locked_run.goal,
          # Use "manual" trigger_type so retries get the same scheduling
          # priority as user-initiated runs. "automatic" with no source PR
          # is treated as auto-pick by ProcessRunQueueJob, which subjects
          # the run to reserved-slot throttling and lowest queue priority —
          # inappropriate for retrying already-approved work.
          trigger_type: "manual",
          status: "queued"
        )
        locked_run.retry!
        created
      end
    rescue ActiveRecord::RecordNotUnique => e
      # Another active run exists for this project+issue or project+PR
      # (enforced by idx_agent_runs_unique_active_issue or
      # idx_agent_runs_unique_active_pr). Inspect the violated constraint
      # so we can reliably find the conflicting run.
      constraint_message = e.cause&.message || e.message

      existing_run =
        if constraint_message.include?("idx_agent_runs_unique_active_issue")
          AgentRun.where(
            project_id: agent_run.project_id,
            issue_id: agent_run.issue_id,
            status: AgentRun::UNFINISHED_STATUSES
          ).where.not(id: agent_run.id).first
        elsif constraint_message.include?("idx_agent_runs_unique_active_pr")
          AgentRun.where(
            project_id: agent_run.project_id,
            source_pull_request_number: agent_run.source_pull_request_number,
            status: AgentRun::UNFINISHED_STATUSES
          ).where.not(id: agent_run.id).first
        end

      # If we couldn't positively identify the conflicting run, bubble up
      # the exception so unexpected unique violations aren't silently hidden.
      raise unless existing_run

      agent_run.retry!

      Rails.logger.info(
        message: "agent_execution.issue_goal_auto_retry_skipped_existing_run",
        original_agent_run_id: agent_run.id,
        existing_agent_run_id: existing_run.id,
        issue_id: agent_run.issue_id,
        project_id: agent_run.project_id
      )
      return
    end

    return unless new_run

    Rails.logger.info(
      message: "agent_execution.issue_goal_auto_retry",
      original_agent_run_id: agent_run.id,
      new_agent_run_id: new_run.id,
      issue_id: agent_run.issue_id,
      project_id: agent_run.project_id
    )

    # Idempotent (advisory lock + SKIP LOCKED). This job is enqueued from
    # AgentRun's after_commit callback when a run transitions to "timeout",
    # regardless of whether the timeout was set by Temporal activities or by
    # StaleRunDetectorJob.
    ProcessRunQueueJob.perform_later
  end

  private

  def eligible_for_retry?(agent_run)
    agent_run.status == "timeout" && agent_run.create_issue_goal?
  end

  # Counts how many previous issue goal runs for the same issue (when present)
  # or for the same goal parameters (when issue is nil) have already been
  # retried (timed out or marked as retried), excluding the current run.
  # This counts retries, not total attempts — the original run is not included.
  def count_previous_retries(agent_run)
    scope =
      if agent_run.issue_id
        agent_run.issue.agent_runs.where(goal: "create_issue")
      else
        AgentRun.where(
          project_id: agent_run.project_id,
          goal: agent_run.goal,
          issue_id: nil,
          provider: agent_run.provider,
          agent_type: agent_run.agent_type,
          custom_prompt: agent_run.custom_prompt,
          source_pull_request_number: agent_run.source_pull_request_number
        )
      end

    scope
      .where(status: %w[timeout retried])
      .where.not(id: agent_run.id)
      .count
  end
end
