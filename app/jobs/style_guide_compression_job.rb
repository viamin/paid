# frozen_string_literal: true

class StyleGuideCompressionJob < ApplicationJob
  queue_as :knowledge

  discard_on ActiveRecord::RecordNotFound

  def perform(style_guide_id, initiated_by_id: nil)
    style_guide = StyleGuide.find(style_guide_id)
    StyleGuides::Compress.call(style_guide: style_guide, user: User.find_by(id: initiated_by_id))
  rescue AgentHarness::Error, StyleGuides::CompressionError => e
    Rails.logger.error(
      message: "style_guides.compression_failed",
      error_class: e.class.name,
      error: e.message,
      style_guide_id: style_guide_id
    )
  end
end
