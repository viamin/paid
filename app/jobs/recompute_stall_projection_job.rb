# frozen_string_literal: true

# Recomputes one project's persisted stall projection outside Inbox
# rendering (RDR-081). Runs under the owning account's tenant context;
# recompute failures are captured on the checkpoint, never re-raised here.
# @spec PARTIAL-CLOSEOUT-042
class RecomputeStallProjectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  discard_on ActiveRecord::RecordNotFound

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: -> { "stall_projection_recompute_#{arguments.first}" }
  )

  def perform(project_id)
    project = Project.find(project_id)
    Issues::StalledCloseoutProjection.recompute(project)
  end
end
