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

    previous_attempts = count_previous_attempts(agent_run)
    if previous_attempts >= MAX_RETRIES
      Rails.logger.info(
        message: "agent_execution.issue_goal_retry_limit_reached",
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id,
        project_id: agent_run.project_id,
        attempts: previous_attempts
      )
      return
    end

    begin
      new_run = AgentRun.transaction do
        created = AgentRun.create!(
          project: agent_run.project,
          issue: agent_run.issue,
          provider: agent_run.provider,
          agent_type: agent_run.agent_type,
          custom_prompt: agent_run.custom_prompt,
          source_pull_request_number: agent_run.source_pull_request_number,
          goal: agent_run.goal,
          trigger_type: "automatic",
          status: "queued"
        )
        agent_run.retry!
        created
      end
    rescue ActiveRecord::RecordNotUnique
      # Another active run exists for this project+issue (enforced by
      # idx_agent_runs_unique_active_issue). Query for it to confirm
      # this is the expected constraint rather than an unrelated violation.
      existing_run = AgentRun.where(
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id,
        status: %w[queued running pending]
      ).where.not(id: agent_run.id).first

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

    Rails.logger.info(
      message: "agent_execution.issue_goal_auto_retry",
      original_agent_run_id: agent_run.id,
      new_agent_run_id: new_run.id,
      issue_id: agent_run.issue_id,
      project_id: agent_run.project_id,
      attempt: previous_attempts + 1
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
  # attempted (timed out or retried), excluding the current run.
  def count_previous_attempts(agent_run)
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
