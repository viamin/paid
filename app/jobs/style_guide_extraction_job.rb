# frozen_string_literal: true

class StyleGuideExtractionJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(project_id)
    project = Project.find(project_id)
    StyleGuides::Extract.call(project: project)
  rescue AgentHarness::Error, StyleGuides::ExtractionError => e
    Rails.logger.error(
      message: "style_guides.extraction_failed",
      error_class: e.class.name,
      error: e.message,
      project_id: project_id
    )
  end
end
