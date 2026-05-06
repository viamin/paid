# frozen_string_literal: true

# Detects agent runs stuck in "running", claimed-queued, or "paused" status
# beyond the configured timeout thresholds.
#
# Running runs use the full agent timeout plus a grace period.
# Claimed queued runs (temporal_workflow_id set but status still "queued") use
# a shorter threshold since the workflow should progress past the provisioning
# phase within minutes.
# Paused runs use their own threshold so guardrail pauses do not block
# auto-pick forever when nobody manually resumes or terminates them.
#
# Stale claimed/paused runs that have not exhausted their requeue budget are
# automatically unclaimed (temporal_workflow_id cleared) so transient failures
# (e.g. worker restart, temporary resource exhaustion) self-heal.
# Runs that exceed MAX_STALE_REQUEUES are timed out like stale running runs.
#
# Scheduled via GoodJob cron every 5 minutes.
class StaleRunDetectorJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "stale_run_detector"
  )

  # Extra buffer beyond agent_timeout before declaring a running run stale.
  # Accounts for container provisioning, git clone, push, and PR creation.
  GRACE_PERIOD = 10.minutes

  # Shorter threshold for claimed queued runs. Container provisioning + clone
  # should complete well within this window. Using the full agent timeout
  # (70 min) for claimed runs delays detection of stuck runs unnecessarily.
  CLAIMED_TIMEOUT = AgentRun.stale_claimed_timeout

  # Paused runs need a manual decision in the happy path, but should not block
  # PR scanning indefinitely if the pause is never acted on.
  PAUSED_TIMEOUT = AgentRun.stale_paused_timeout

  # Issues with paid_state=in_progress are only eligible for recovery once
  # they've been orphaned for at least this long. Avoids racing with run
  # creation (create_agent_run_activity sets in_progress then enqueues the
  # workflow, which may take a few seconds to produce a visible AgentRun).
  ORPHANED_IN_PROGRESS_AGE = 15.minutes

  # Maximum times a stale claimed run can be automatically unclaimed before
  # being timed out. Prevents infinite retry loops when the underlying
  # issue is persistent (e.g. misconfigured project, missing credentials).
  MAX_STALE_REQUEUES = AgentRun::MAX_STALE_REQUEUES
  MAX_STALE_SKIPS = AgentRun::MAX_STALE_SKIPS

  def perform
    job_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    running_threshold = agent_timeout_with_grace.ago
    claimed_threshold = CLAIMED_TIMEOUT.ago
    paused_threshold = PAUSED_TIMEOUT.ago
    resolved = 0
    unclaimed = 0
    requeued = 0
    skipped = 0
    recovered_orphans = 0

    stale_running_runs(running_threshold).find_each do |agent_run|
      resolved += 1 if resolve_stale_run(agent_run)
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    stale_claimed_runs(claimed_threshold).find_each do |agent_run|
      case unclaim_stale_claimed_run(agent_run)
      when :unclaimed
        unclaimed += 1
      when :exhausted
        resolved += 1 if resolve_stale_run(agent_run)
      when :skip
        skipped += 1
      end
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    stale_paused_runs(paused_threshold).find_each do |agent_run|
      case requeue_stale_paused_run(agent_run)
      when :requeued
        requeued += 1
      when :exhausted
        resolved += 1 if resolve_stale_run(agent_run)
      when :skip
        skipped += 1
      end
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.resolve_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    recovered_orphans = recover_orphaned_in_progress_issues

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_started_at) * 1000).round
    Rails.logger.info(
      message: "stale_run_detector.completed",
      resolved: resolved,
      unclaimed: unclaimed,
      requeued: requeued,
      skipped: skipped,
      recovered_orphans: recovered_orphans,
      duration_ms: duration_ms
    )

    ProcessRunQueueJob.perform_later if resolved > 0 || unclaimed > 0 || requeued > 0 || recovered_orphans > 0
  end

  private

  # Finds issues stuck in paid_state=in_progress that have no active agent
  # run. This can happen when a Temporal workflow crashes before reaching a
  # terminal activity, or when an agent run is deleted without updating the
  # associated issue. Without recovery these issues are invisible to auto-pick
  # (which skips in_progress) and invisible to all other cleanup jobs (which
  # operate top-down from AgentRun records).
  def recover_orphaned_in_progress_issues
    active_issue_ids = AgentRun.where(status: AgentRun::UNFINISHED_STATUSES)
      .where.not(issue_id: nil)
      .select(:issue_id)

    orphans = Issue.where(paid_state: "in_progress", is_pull_request: false)
      .where.not(id: active_issue_ids)
      .where("updated_at < ?", ORPHANED_IN_PROGRESS_AGE.ago)

    count = 0
    orphans.find_each do |issue|
      issue.with_lock do
        issue.reload
        next unless issue.paid_state == "in_progress"
        next if AgentRun.where(issue: issue, status: AgentRun::UNFINISHED_STATUSES).exists?

        issue.update!(paid_state: "new")
        count += 1
        Rails.logger.info(
          message: "stale_run_detector.recovered_orphaned_in_progress",
          issue_id: issue.id,
          issue_number: issue.github_number,
          project_id: issue.project_id
        )
      end
    rescue => e
      Rails.logger.error(
        message: "stale_run_detector.recover_orphan_failed",
        issue_id: issue.id,
        error: e.message
      )
    end
    count
  end

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

  # Claimed queued runs (temporal_workflow_id set, status "queued") whose
  # last update was before the threshold. Uses updated_at to approximate
  # when the run was claimed, since a run may have spent a long time in
  # "queued" before being claimed.
  def stale_claimed_runs(threshold)
    AgentRun.claimed.where("updated_at < ?", threshold)
  end

  # Runs stuck in "paused" whose pause timestamp is before the threshold.
  def stale_paused_runs(threshold)
    AgentRun.paused.where("paused_at < ?", threshold)
  end

  # Attempts to unclaim a stale claimed queued run.
  # Returns :unclaimed if successfully unclaimed, :exhausted if requeue/skip budget
  # is spent (caller should time out), or :skip if the run should be retried later.
  #
  # If a Temporal workflow was already started for this run (temporal_workflow_id
  # is a real workflow ID, not just "claimed"), we cancel it *before* unclaiming
  # so ProcessRunQueueJob can start a fresh workflow without racing the old one.
  # If cancellation fails with a non-NOT_FOUND error, we skip the unclaim to
  # avoid duplicate workflows — the next detector cycle will retry.
  def unclaim_stale_claimed_run(agent_run)
    result = requeue_stale_unfinished_run(agent_run, claimed_requeue_policy)
    result == :requeued ? :unclaimed : result
  end

  def requeue_stale_paused_run(agent_run)
    requeue_stale_unfinished_run(agent_run, paused_requeue_policy)
  end

  def requeue_stale_unfinished_run(agent_run, policy)
    old_resources = {}

    agent_run.with_lock do
      agent_run.reload
      return skip_requeue(agent_run, "finished") if agent_run.finished?
      return skip_requeue(agent_run, "status_changed") unless agent_run.status == policy.fetch(:status)
      if policy[:claimed]
        return skip_requeue(agent_run, "no_longer_claimed") unless agent_run.temporal_workflow_id.present?
      end
      return skip_requeue(agent_run, "not_stale") unless stale_for_requeue?(agent_run, policy)
      return :exhausted if timeout_before_requeue?(agent_run, policy)
      return :exhausted if agent_run.stale_requeue_count >= MAX_STALE_REQUEUES

      old_resources = captured_resources(agent_run)

      unless cancel_temporal_workflow(agent_run, agent_run.temporal_workflow_id)
        return skip_after_cancel_failure(agent_run)
      end

      agent_run.update!(requeue_attributes(agent_run, policy))
      agent_run.log!("system", stale_requeue_log(agent_run))

      Rails.logger.info(
        message: "stale_run_detector.#{policy[:log_action]}_stale_#{agent_run.status_before_last_save}_run",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        stale_requeue_count: agent_run.stale_requeue_count
      )
    end

    cleanup_docker_resources_by_id(agent_run, old_resources)

    :requeued
  end

  def captured_resources(agent_run)
    {
      container_id: agent_run.container_id,
      service_container_ids: agent_run.service_container_ids.dup,
      service_environment: agent_run.service_environment&.dup,
      stale_requeue_count: agent_run.stale_requeue_count
    }
  end

  def claimed_requeue_policy
    {
      status: "queued",
      stale_attribute: :updated_at,
      threshold: CLAIMED_TIMEOUT.ago,
      reset_attributes: {},
      claimed: true,
      log_action: "unclaimed"
    }
  end

  def paused_requeue_policy
    {
      status: "paused",
      stale_attribute: :paused_at,
      threshold: PAUSED_TIMEOUT.ago,
      reset_attributes: {
        started_at: nil,
        completed_at: nil,
        duration_seconds: nil,
        paused_at: nil,
        guardrail_violation_type: nil,
        guardrail_context: nil
      },
      timeout_before_requeue: true,
      log_action: "requeued"
    }
  end

  def stale_for_requeue?(agent_run, policy)
    stale_at = agent_run.public_send(policy.fetch(:stale_attribute))
    stale_at.present? && stale_at < policy.fetch(:threshold)
  end

  def timeout_before_requeue?(agent_run, policy)
    policy[:timeout_before_requeue] && non_restartable_paused_run?(agent_run)
  end

  def non_restartable_paused_run?(agent_run)
    guardrail_violation_type(agent_run) == "time_limit" && agent_run.iterations.to_i.zero?
  end

  def guardrail_violation_type(agent_run)
    agent_run.guardrail_violation_type.presence ||
      agent_run.guardrail_context&.dig("violation_type").presence
  end

  def requeue_attributes(agent_run, policy)
    {
      status: "queued",
      stale_requeue_count: agent_run.stale_requeue_count + 1,
      stale_skip_count: 0,
      temporal_workflow_id: nil,
      temporal_run_id: nil,
      service_environment: nil,
      container_id: nil,
      service_container_ids: []
    }.merge(policy.fetch(:reset_attributes))
  end

  def stale_requeue_log(agent_run)
    previous_status = agent_run.status_before_last_save
    if previous_status == "queued"
      "Stale claimed queued run unclaimed by stale run detector (attempt #{agent_run.stale_requeue_count}/#{MAX_STALE_REQUEUES})"
    else
      "Stale #{previous_status} run requeued by stale run detector (attempt #{agent_run.stale_requeue_count}/#{MAX_STALE_REQUEUES})"
    end
  end

  def skip_after_cancel_failure(agent_run)
    agent_run.increment!(:stale_skip_count)
    log_skip(agent_run, "temporal_cancel_failed")

    return :exhausted if agent_run.stale_skip_count >= MAX_STALE_SKIPS

    :skip
  end

  def skip_requeue(agent_run, reason)
    log_skip(agent_run, reason)
    :skip
  end

  def log_skip(agent_run, reason)
    Rails.logger.warn(
      message: "stale_run_detector.skipped_stale_run",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      status: agent_run.status,
      reason: reason,
      stale_requeue_count: agent_run.stale_requeue_count,
      stale_skip_count: agent_run.stale_skip_count
    )
  end

  def resolve_stale_run(agent_run)
    old_resources = {}

    agent_run.with_lock do
      agent_run.reload
      return false if agent_run.finished?

      old_resources = captured_resources(agent_run)

      agent_run.update!(
        status: "timeout",
        completed_at: Time.current,
        error_message: "#{AgentRun::STALE_DETECTOR_ERROR_PREFIX}: stuck in '#{agent_run.status}' beyond timeout threshold",
        duration_seconds: agent_run.duration
      )
      agent_run.log!("system", "Run marked as timed out by stale run detector")

      if (issue = agent_run.issue)
        # Review-goal failures restore "completed" instead of "failed" so
        # auto-pick is not blocked by a transient review follow-up failure.
        target_state = agent_run.review_goal? ? "completed" : "failed"
        issue.update!(paid_state: target_state) unless issue.paid_state == target_state
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

    cleanup_docker_resources_by_id(agent_run, old_resources)

    true
  end

  # Cancels a Temporal workflow by its captured workflow_id. Returns true if
  # the workflow was successfully cancelled or was not found (already completed).
  # Returns false if cancellation failed for another reason, signaling that
  # the caller should not proceed with requeuing to avoid duplicate workflows.
  def cancel_temporal_workflow(agent_run, workflow_id)
    return true if workflow_id.blank?
    return true if workflow_id == AgentRun::CLAIMED_SENTINEL

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

  # Cleans up docker resources using IDs captured under the row lock.
  # Reconnects to the container by old_container_id directly (rather
  # than going through agent_run.cleanup_container) so we never read a
  # potentially-changed container_id from the DB. Uses a conditional update
  # (WHERE container_id = old_id) to avoid clobbering a new container_id
  # if the run was re-provisioned after the lock was released.
  #
  # Service containers are cleaned up using the captured old_service_container_ids
  # rather than reading from agent_run, which may have been cleared under the lock.
  def cleanup_docker_resources_by_id(agent_run, old_resources = {})
    old_container_id = old_resources[:container_id]

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

    cleanup_service_containers(agent_run, old_resources)
  end

  # Cleans up service containers using IDs captured under the row lock.
  # Assigns the captured state back onto the in-memory agent_run so
  # ServiceProvisioner#cleanup can read the exact services and database name
  # provisioned for the old attempt (the DB record was already cleared inside
  # the lock). The provisioner clears only the service_container_ids column
  # so the restored service_environment is not persisted back to the DB.
  def cleanup_service_containers(agent_run, old_resources)
    begin
      service_container_ids = old_resources[:service_container_ids]
      service_environment = old_resources[:service_environment]

      # Restore captured IDs in memory so the provisioner can read them;
      # the DB record was already cleared inside the lock.
      agent_run.service_container_ids = service_container_ids if service_container_ids.present?
      agent_run.service_environment = service_environment if service_environment.present?
      Containers::ServiceProvisioner.new.cleanup(agent_run,
        stale_requeue_count: old_resources[:stale_requeue_count])
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
