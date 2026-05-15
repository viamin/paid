# frozen_string_literal: true

# One-time backfill for projects that already had auto-pick enabled before
# eager queue seeding shipped. Without this pass, unchanged eligible issues can
# remain unqueued indefinitely because incremental GitHub sync only re-enqueues
# issues it touches after last_issue_sync_at.
class AutoPickQueueBackfillJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "auto_pick_queue_backfill"
  )

  CACHE_NAMESPACE = "auto_pick_queue_backfill/v1"

  def perform
    return if completed?

    processed = 0

    Project.where(auto_pick_enabled: true).find_each do |project|
      next if project_backfilled?(project.id)

      Issues::BulkEnqueueEligible.call(project: project, skip_project_gate: true)
      mark_project_backfilled(project.id)
      processed += 1
    rescue => e
      Rails.logger.error(
        message: "auto_pick_queue_backfill.project_failed",
        project_id: project.id,
        error: e.message
      )
    end

    mark_completed if remaining_project_ids.empty?

    Rails.logger.info(
      message: "auto_pick_queue_backfill.completed",
      processed_projects: processed,
      remaining_projects: remaining_project_ids.size
    )
  end

  private

  def completed?
    Rails.cache.read(completed_cache_key) == true
  end

  def mark_completed
    Rails.cache.write(completed_cache_key, true)
  end

  def project_backfilled?(project_id)
    Rails.cache.read(project_cache_key(project_id)) == true
  end

  def mark_project_backfilled(project_id)
    Rails.cache.write(project_cache_key(project_id), true)
  end

  def remaining_project_ids
    Project.where(auto_pick_enabled: true).pluck(:id).reject { |id| project_backfilled?(id) }
  end

  def completed_cache_key
    "#{CACHE_NAMESPACE}/completed"
  end

  def project_cache_key(project_id)
    "#{CACHE_NAMESPACE}/projects/#{project_id}"
  end
end
