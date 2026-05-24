# frozen_string_literal: true

module StyleGuides
  class EnqueueCompression
    attr_reader :style_guide, :initiated_by, :source

    def initialize(style_guide:, initiated_by: nil, source:)
      @style_guide = style_guide
      @initiated_by = initiated_by
      @source = source
    end

    def self.call(...)
      new(...).call
    end

    def call
      StyleGuideCompressionJob.perform_later(style_guide.id)

      Rails.logger.info(
        message: "style_guides.compression_enqueued",
        style_guide_id: style_guide.id,
        account_id: style_guide.account_id,
        project_id: style_guide.project_id,
        source: source,
        actor_user_id: initiated_by&.id,
        actor_user_email: initiated_by&.email
      )
    end
  end
end
