# frozen_string_literal: true

class PartialCloseoutProjectionReconciliationSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "partial_closeout_projection_reconciliation_sweep"
  )

  # @spec PARTIAL-CLOSEOUT-042
  def perform
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @projects_checked = 0
    @projects_enqueued = 0
    TenantContext.with_system_access do
      Project.includes(account: :tenant_setting).find_in_batches do |projects|
        reconcile(projects.select { |project| projection_enabled?(project) })
      end
    end
    log_completion
  end

  private

  def projection_enabled?(project)
    FeatureFlags.enabled?(:partial_closeout_lane_read_model, project:)
  end

  def reconcile(projects)
    return if projects.empty?

    @projects_checked += projects.size
    checkpoints = PartialCloseoutProjection.where(project_id: projects.map(&:id)).index_by(&:project_id)
    snapshots = Issues::PartialCloseoutProjectionInputWatermark.for_projects(projects)
    projects.each { |project| enqueue_if_stale(project, checkpoints[project.id], snapshots.fetch(project.id)) }
  end

  def enqueue_if_stale(project, checkpoint, input_snapshot)
    return if checkpoint&.computed_at? && checkpoint.input_watermark == input_snapshot.watermark &&
      checkpoint.input_fingerprint == input_snapshot.fingerprint

    RecomputePartialCloseoutProjectionJob.perform_later(project.id)
    @projects_enqueued += 1
  end

  def log_completion
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1_000).round
    Rails.logger.info(
      message: "partial_closeout_projection.reconciliation_sweep_completed",
      projects_checked: @projects_checked,
      projects_enqueued: @projects_enqueued,
      duration_ms:
    )
  end
end
