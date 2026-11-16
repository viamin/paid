# frozen_string_literal: true

class RecomputePartialCloseoutProjectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    perform_limit: 1,
    key: -> { "partial_closeout_projection_#{arguments.first}" }
  )

  def perform(project_id)
    project = Project.find(project_id)
    Issues::StalledCloseoutProjection.call(project:)
  end

  def notification_project_id
    arguments.first
  end
end
