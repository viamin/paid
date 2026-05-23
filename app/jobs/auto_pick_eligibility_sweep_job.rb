# frozen_string_literal: true

# Periodic sweep that re-evaluates all open issues for auto-pick eligibility.
#
# The auto-pick queue is primarily event-driven (GitHub sync callbacks, paid_state
# transitions, dependency resolution). This sweep closes the gap for issues that
# became eligible between sync cycles — for example, when a runner was temporarily
# unavailable, a transient error caused a silent skip, or an issue was backfilled
# by reconcile_open_issues without being added to the eligible list.
#
# Runs every 15 minutes via GoodJob cron. Each invocation calls
# {Issues::BulkEnqueueEligible} for every active project with auto-pick enabled,
# which internally filters to only eligible issues and skips those that already
# have an active agent run.
#
# Concurrency is limited to a single invocation to avoid stacking sweeps when
# the queue is large or the DB is slow.
class AutoPickEligibilitySweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "auto_pick_eligibility_sweep"
  )

  def perform
    processed = 0
    enqueued = 0

    eligible_projects.find_each do |project|
      next unless Issues::AutoPickProjectGate.call(project)

      runs = Issues::BulkEnqueueEligible.call(project: project, skip_project_gate: true)
      processed += 1
      enqueued += runs.count(&:previously_new_record?)
    rescue => e
      Rails.logger.error(
        message: "auto_pick_eligibility_sweep.project_failed",
        project_id: project.id,
        error: e.message
      )
    end

    Rails.logger.info(
      message: "auto_pick_eligibility_sweep.completed",
      processed_projects: processed,
      enqueued_runs: enqueued
    )
  end

  private

  def eligible_projects
    Project.active.where(auto_pick_enabled: true).includes(:account, :created_by)
  end
end
