# frozen_string_literal: true

# Detects agent runs stuck in "running" or "pending" status beyond
# the configured timeout thresholds.
#
# Running runs use the full agent timeout plus a grace period.
# Pending runs use a shorter threshold since the pending→running
# transition (container provisioning + clone) should complete in minutes.
#
# Stale pending runs that have not exhausted their requeue budget are
# automatically requeued (reset to "queued") so transient failures
# (e.g. worker restart, temporary resource exhaustion) self-heal.
# Runs that exceed MAX_STALE_REQUEUES are timed out like stale running runs.
#
# Scheduled via GoodJob cron every 5 minutes.
class StaleRunDetectorJob < ApplicationJob
  queue_as :maintenance

  # Extra buffer beyond agent_timeout before declaring a running run stale.
  # Accounts for container provisioning, git clone, push, and PR creation.
  GRACE_PERIOD = 10.minutes

  # Shorter threshold for pending runs. Container provisioning + clone
  # should complete well within this window. Using the full agent timeout
  # (70 min) for pending runs delays detection of stuck runs unnecessarily.
  PENDING_TIMEOUT = 15.minutes

  # Maximum times a stale pending run can be automatically requeued before
  # being timed out. Prevents infinite retry loops when the underlying
  # issue is persistent (e.g. misconfigured project, missing credentials).
  MAX_STALE_REQUEUES = 2

  def perform
    job_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    running_threshold = agent_timeout_with_grace.ago
    pending_threshold = PENDING_TIMEOUT.ago
    resolved = 0
    requeued = 0

    stale_running_runs(running_threshold).find_each do |agent_run|
      resolved += 1 if resolve_stale_run(agent_run)
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    stale_pending_runs(pending_threshold).find_each do |agent_run|
      case requeue_stale_pending_run(agent_run)
      when :requeued
        requeued += 1
      when :exhausted
        resolved += 1 if resolve_stale_run(agent_run)
      end
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_started_at) * 1000).round
    Rails.logger.info(
      message: "stale_run_detector.completed",
      resolved: resolved,
      requeued: requeued,
      duration_ms: duration_ms
    )

    ProcessRunQueueJob.perform_later if resolved > 0 || requeued > 0
  end

  private

  # Uses the default timeout rather than per-user maximums. Individual run
  # timeouts are enforced by the Temporal workflow; this job is a safety net
  # for orphaned runs where the workflow died. Using UserSetting.maximum
  # would let a single user's large timeout delay stale-run detection for
  # every other user's runs.
  def agent_timeout_with_grace
    AGENT_TIMEOUT_DEFAULT.seconds + GRACE_PERIOD
  end

  # Runs stuck in "running" that started before the threshold.
  def stale_running_runs(threshold)
    AgentRun.running.where("started_at < ?", threshold)
  end

  # Runs stuck in "pending" whose last update was before the threshold.
  # Uses updated_at to approximate when the run entered "pending", since a run
  # may have spent a long time in "queued" before transitioning to "pending".
  def stale_pending_runs(threshold)
    AgentRun.pending.where("updated_at < ?", threshold)
  end

  # Attempts to requeue a stale pending run.
  # Returns :requeued if successfully requeued, :exhausted if requeue budget
  # is spent (caller should time out), or :skip if the run is no longer
  # stale/pending (e.g. it finished, transitioned to running, or was recently updated).
  #
  # If a Temporal workflow was already started for this run (temporal_workflow_id
  # is present), we cancel it *before* requeuing so ProcessRunQueueJob can start
  # a fresh workflow without racing the old one. If cancellation fails with a
  # non-NOT_FOUND error, we skip the requeue to avoid duplicate workflows — the
  # next detector cycle will retry.
  def requeue_stale_pending_run(agent_run)
    pending_threshold = PENDING_TIMEOUT.ago
    old_container_id = nil
    old_workflow_id = nil

    agent_run.with_lock do
      agent_run.reload
      return :skip if agent_run.finished?
      return :skip unless agent_run.status == "pending"
      return :skip unless agent_run.updated_at < pending_threshold
      return :exhausted if agent_run.stale_requeue_count >= MAX_STALE_REQUEUES

      old_container_id = agent_run.container_id
      old_workflow_id = agent_run.temporal_workflow_id

      # Cancel the old Temporal workflow before requeuing. If cancellation
      # fails (non-NOT_FOUND), skip this requeue to prevent duplicate workflows.
      unless cancel_temporal_workflow(agent_run, old_workflow_id)
        return :skip
      end

      agent_run.update!(
        status: "queued",
        stale_requeue_count: agent_run.stale_requeue_count + 1,
        temporal_workflow_id: nil,
        temporal_run_id: nil,
        service_environment: nil
      )
      agent_run.log!("system", "Stale pending run requeued by stale run detector (attempt #{agent_run.stale_requeue_count}/#{MAX_STALE_REQUEUES})")

      Rails.logger.info(
        message: "stale_run_detector.requeued_stale_pending_run",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        stale_requeue_count: agent_run.stale_requeue_count
      )
    end

    cleanup_docker_resources_by_id(agent_run, old_container_id)

    :requeued
  end

  def resolve_stale_run(agent_run)
    old_container_id = nil

    agent_run.with_lock do
      agent_run.reload
      return false if agent_run.finished?

      old_container_id = agent_run.container_id

      agent_run.timeout!(error: "Stale run detected: stuck in '#{agent_run.status}' beyond timeout threshold")
      agent_run.log!("system", "Run marked as timed out by stale run detector")

      if (issue = agent_run.issue)
        issue.update!(paid_state: "failed") unless issue.paid_state == "failed"
      end

      Rails.logger.warn(
        message: "stale_run_detector.resolved_stale_run",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        previous_status: agent_run.status_before_last_save,
        started_at: agent_run.started_at,
        created_at: agent_run.created_at
      )
    end

    cleanup_docker_resources_by_id(agent_run, old_container_id)

    true
  end

  # Cancels a Temporal workflow by its captured workflow_id. Returns true if
  # the workflow was successfully cancelled or was not found (already completed).
  # Returns false if cancellation failed for another reason, signaling that
  # the caller should not proceed with requeuing to avoid duplicate workflows.
  def cancel_temporal_workflow(agent_run, workflow_id)
    return true if workflow_id.blank?

    handle = Paid.temporal_client.workflow_handle(workflow_id)
    handle.cancel
    true
  rescue Temporalio::Error::RPCError => e
    raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    Rails.logger.info(
      message: "stale_run_detector.cancel_workflow_not_found",
      agent_run_id: agent_run.id,
      temporal_workflow_id: workflow_id
    )
    true
  rescue => e
    Rails.logger.warn(
      message: "stale_run_detector.cancel_workflow_failed",
      agent_run_id: agent_run.id,
      temporal_workflow_id: workflow_id,
      error_class: e.class.name,
      error: e.message
    )
    false
  end

  # Cleans up docker resources using the container_id captured under the row
  # lock. Reconnects to the container by old_container_id directly (rather
  # than going through agent_run.cleanup_container) so we never read a
  # potentially-changed container_id from the DB. Uses a conditional update
  # (WHERE container_id = old_id) to avoid clobbering a new container_id
  # if the run was re-provisioned after the lock was released.
  def cleanup_docker_resources_by_id(agent_run, old_container_id)
    if old_container_id.present?
      begin
        service = Containers::Provision.reconnect(
          agent_run: agent_run,
          container_id: old_container_id,
          worktree_path: agent_run.worktree_path
        )
        service.cleanup(force: true)
      rescue => e
        Rails.logger.warn(
          message: "stale_run_detector.container_cleanup_failed",
          agent_run_id: agent_run.id,
          error_class: e.class.name,
          error: e.message
        )
      end
      # Only clear container_id if it hasn't changed since we captured it
      AgentRun.where(id: agent_run.id, container_id: old_container_id)
              .update_all(container_id: nil)
    end

    begin
      Containers::ServiceProvisioner.new.cleanup(agent_run)
    rescue => e
      Rails.logger.warn(
        message: "stale_run_detector.service_cleanup_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
