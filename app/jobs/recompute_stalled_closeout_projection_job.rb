# frozen_string_literal: true

# Recomputes one project's partial-closeout stall projection (RDR-081)
# outside Inbox rendering. Admission failures bubble up to this job's
# terminal-failure reporting; the projection service has already recorded
# bounded failure metadata on the checkpoint and kept the previous rows.
# @spec PARTIAL-CLOSEOUT-042
class RecomputeStalledCloseoutProjectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    perform_limit: 1,
    key: -> { "recompute_stalled_closeout_projection/#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  def perform(project_id)
    project = Project.find(project_id)
    result = Issues::StalledCloseoutProjection.recompute(project)

    Rails.logger.info(
      message: "issues.stall_projection_recomputed",
      project_id: project.id,
      account_id: project.account_id,
      generation: result.generation,
      stall_count: result.stall_count
    )
  end
end
