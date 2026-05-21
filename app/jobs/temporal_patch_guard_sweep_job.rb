# frozen_string_literal: true

class TemporalPatchGuardSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "temporal_patch_guard_sweep"
  )

  def perform
    report = TemporalPatchGuards::Sweep.new.call

    Rails.logger.info(
      message: "temporal.patch_guard_sweep.completed",
      workflow_count: report.workflow_summaries.size,
      eligible_guard_count: report.eligible_guards.size,
      workflows: report.workflow_summaries
    )

    return if report.eligible_guards.empty?

    Rails.logger.warn(
      message: "temporal.patch_guard_sweep.eligible_guards",
      eligible_guard_names: report.eligible_guards.map(&:name),
      eligible_workflow_types: report.eligible_guards.map(&:workflow_type).uniq,
      policy_path: "docs/PATCH_GUARDS.md"
    )
  rescue => e
    Rails.logger.error(
      message: "temporal.patch_guard_sweep.failed",
      error_class: e.class.name,
      error: e.message
    )
    raise
  end
end
