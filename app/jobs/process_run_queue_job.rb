# frozen_string_literal: true

require "digest/md5"
require "set"

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
      skipped_ids = Set.new

      loop do
        # Peek at the next queued run without claiming it, so we can check
        # per-user capacity before transitioning to "pending". This avoids
        # an unnecessary queued -> pending -> queued status flip (and its
        # associated broadcasts/metrics) for runs that can't start yet.
        next_run = AgentRun.peek_next_queued_run(exclude_ids: skipped_ids.to_a)

        # When the queue is truly empty (not just all skipped), auto-pick
        # unblocked issues to keep agents productive. Skip auto-pick when
        # every queued run was skipped due to capacity limits — scanning
        # projects and creating more runs would be wasteful.
        unless next_run
          if skipped_ids.empty? && auto_pick_unblocked_issues
            next
          else
            break
          end
        end

        # Enforce per-user concurrency limit.
        user = next_run.project.effective_owner
        unless AgentRun.has_run_capacity?(user: user)
          skipped_ids.add(next_run.id)
          next
        end

        # User has capacity — now atomically claim the run.
        # claim_next_queued_run returns nil if another process claimed or
        # transitioned this run between peek and claim. Skip it and continue
        # processing the queue rather than stopping entirely.
        agent_run = AgentRun.claim_next_queued_run(target_id: next_run.id)
        unless agent_run
          skipped_ids.add(next_run.id)
          next
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

  # Auto-picks unblocked issues for active projects, creating new queued
  # agent runs. Returns true if any runs were created so the main loop
  # can process them through the normal claim-and-start flow.
  def auto_pick_unblocked_issues
    # If the last auto-pick pass created no runs, skip further attempts to
    # avoid spinning when no eligible issues exist.
    if defined?(@auto_pick_last_created_any) && @auto_pick_last_created_any == false
      return false
    end

    created_any = false

    Project.active.where(auto_pick_enabled: true).find_each do |project|
      created_any = true if Issues::AutoPick.new(project).call
    end

    @auto_pick_last_created_any = created_any
  end

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
