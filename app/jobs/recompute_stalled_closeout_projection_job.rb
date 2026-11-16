# frozen_string_literal: true

# Recomputes one project's persisted partial-closeout stall projection
# (RDR-081 Option B) outside Inbox rendering. Admission stays with live
# `DefaultCandidateSource.eligible_scope`; this job only refreshes the
# display-only read model. Failures keep the previous projection and are
# recorded on the checkpoint; the sweep self-heals.
# @spec PARTIAL-CLOSEOUT-042
class RecomputeStalledCloseoutProjectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: -> { "stalled_closeout_projection_recompute_#{arguments.first}" }
  )

  def perform(project_id)
    project = Project.find(project_id)
    return unless Issues::StalledCloseoutProjection.enabled?(project)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Issues::StalledCloseoutProjection.recompute(project)
    duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    return if result.success?

    Rails.logger.warn(
      message: "issues.stalled_closeout_projection_recompute_job_failed",
      project_id: project_id,
      duration_ms: duration_ms.round(2),
      error_class: result.error.class.name
    )
  end
end
