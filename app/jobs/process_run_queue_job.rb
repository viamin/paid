# frozen_string_literal: true

require "digest/md5"

class ProcessRunQueueJob < ApplicationJob
  queue_as :default

  # Advisory lock key derived from class name to avoid collisions with other locks.
  ADVISORY_LOCK_KEY = Digest::MD5.hexdigest("ProcessRunQueueJob").to_i(16) % (2**31 - 1)

  # Maximum consecutive workflow start failures before aborting the loop.
  # Prevents cascading failures when Temporal is down.
  MAX_CONSECUTIVE_FAILURES = 3

  def perform
    # Use a PostgreSQL advisory lock to ensure only one job processes the queue at a time.
    # If another instance is already running, this job exits immediately (no-op).
    acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return unless acquired

    begin
      consecutive_failures = 0

      while AgentRun.has_run_capacity?
        agent_run = AgentRun.claim_next_queued_run
        break unless agent_run

        # Enforce per-user concurrency limit. The system-wide check above gates
        # the loop, but the user may have a lower personal cap. If so, re-queue
        # the run; it will be retried on the next job execution when capacity
        # opens up.
        #
        # We exclude the just-claimed run from the count because claim already
        # moved it to "pending" (active). We're deciding whether to actually
        # start it, so we compare prior active count against the cap.
        user = agent_run.project.created_by
        if user
          user_project_ids = Project.where(created_by: user).select(:id)
          user_active_count = AgentRun.active.where(project_id: user_project_ids)
            .where.not(id: agent_run.id).count
          max = AgentRun.effective_max_concurrent_runs(user)
          unless user_active_count < max
            agent_run.update!(status: "queued")
            break
          end
        end

        if start_claimed_run(agent_run)
          consecutive_failures = 0
        else
          consecutive_failures += 1
          break if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
        end
      end
    ensure
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})") if acquired
    end
  end

  private

  def start_claimed_run(agent_run)
    workflow_input = {
      project_id: agent_run.project_id,
      agent_type: agent_run.agent_type,
      agent_run_id: agent_run.id,
      goal: agent_run.goal
    }
    workflow_input[:issue_id] = agent_run.issue_id if agent_run.issue_id
    workflow_input[:custom_prompt] = agent_run.custom_prompt if agent_run.custom_prompt.present?
    workflow_input[:source_pull_request_number] = agent_run.source_pull_request_number if agent_run.source_pull_request_number

    workflow_id = "queued-#{agent_run.project_id}-#{agent_run.id}-#{Time.current.to_i}"

    Paid.temporal_client.start_workflow(
      Workflows::AgentExecutionWorkflow,
      workflow_input,
      id: workflow_id,
      task_queue: Paid.task_queue
    )

    Rails.logger.info(
      message: "process_run_queue.started_queued_run",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id
    )
    true
  rescue => e
    agent_run.fail!(error: "Failed to start workflow: #{e.message}")
    Rails.logger.error(
      message: "process_run_queue.start_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
    false
  end
end
