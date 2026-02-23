# frozen_string_literal: true

class ProcessRunQueueJob < ApplicationJob
  queue_as :default

  # Advisory lock key for single-execution of queue processing.
  # Prevents concurrent jobs from each claiming runs and exceeding MAX_CONCURRENT_RUNS.
  ADVISORY_LOCK_KEY = 73_982_614 # arbitrary fixed integer

  def perform
    # Use a PostgreSQL advisory lock to ensure only one job processes the queue at a time.
    # If another instance is already running, this job exits immediately (no-op).
    acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return unless acquired

    begin
      while AgentRun.has_run_capacity?
        agent_run = AgentRun.claim_next_queued_run
        break unless agent_run

        start_claimed_run(agent_run)
      end
    ensure
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  private

  def start_claimed_run(agent_run)
    workflow_input = {
      project_id: agent_run.project_id,
      agent_type: agent_run.agent_type,
      agent_run_id: agent_run.id
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
  rescue => e
    agent_run.fail!(error: "Failed to start workflow: #{e.message}")
    Rails.logger.error(
      message: "process_run_queue.start_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end
end
