# frozen_string_literal: true

# Recomputes one project's persisted partial-closeout stall projection outside
# Inbox rendering (RDR-081). Enqueued by admission-input triggers and the
# self-healing sweep; performs only for enrolled projects, under the owning
# account's tenant context.
# @spec PARTIAL-CLOSEOUT-042
class PartialCloseoutStallProjectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: ->(job) { "partial_closeout_stall_projection:#{job.arguments.first}" }
  )

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project
    return unless Issues::StalledCloseoutProjection.enabled?(project)

    result = Issues::StalledCloseoutProjection.recompute!(project)
    if result.success?
      Rails.logger.info(
        message: "partial_closeout.stall_projection_recomputed",
        project_id: project.id,
        generation: result.generation,
        stalled_count: result.stalled_count
      )
    else
      Rails.logger.error(
        message: "partial_closeout.stall_projection_recompute_failed",
        project_id: project.id,
        error_class: result.error.class.name,
        error: result.error.message
      )
    end
  end
end
