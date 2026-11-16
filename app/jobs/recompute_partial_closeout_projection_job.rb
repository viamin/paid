# frozen_string_literal: true

class RecomputePartialCloseoutProjectionJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(project_id)
    project = Project.find(project_id)
    Issues::StalledCloseoutProjection.call(project:)
  end

  def notification_project_id
    arguments.first
  end
end
