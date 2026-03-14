# frozen_string_literal: true

# Detects agent runs stuck in "running" or "pending" status beyond
# the configured agent timeout plus a grace period.
#
# This catches orphaned runs where the Temporal workflow died or
# disconnected after the agent activity completed but before the
# status could be updated. Runs are marked as "timeout" so they
# stop blocking the run queue and show up correctly in the UI.
#
# Scheduled via GoodJob cron every 5 minutes.
class StaleRunDetectorJob < ApplicationJob
  queue_as :maintenance

  # Extra buffer beyond agent_timeout before declaring a run stale.
  # Accounts for container provisioning, git clone, push, and PR creation.
  GRACE_PERIOD = 10.minutes

  def perform
    job_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timeout_threshold = agent_timeout_with_grace.ago
    resolved = 0

    stale_running_runs(timeout_threshold).find_each do |agent_run|
      resolved += 1 if resolve_stale_run(agent_run)
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    stale_pending_runs(timeout_threshold).find_each do |agent_run|
      resolved += 1 if resolve_stale_run(agent_run)
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
      duration_ms: duration_ms
    )

    ProcessRunQueueJob.perform_later if resolved > 0
  end

  private

  def agent_timeout_with_grace
    Rails.application.config.x.agent_timeout.seconds + GRACE_PERIOD
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

  def resolve_stale_run(agent_run)
    agent_run.with_lock do
      agent_run.reload
      return false if agent_run.finished?

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

    cleanup_docker_resources(agent_run)

    true
  end

  def cleanup_docker_resources(agent_run)
    begin
      agent_run.cleanup_container(force: true)
    rescue => e
      Rails.logger.warn(
        message: "stale_run_detector.container_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    begin
      Containers::ServiceProvisioner.new.cleanup(agent_run)
    rescue => e
      Rails.logger.warn(
        message: "stale_run_detector.service_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end
  end
end
