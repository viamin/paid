# frozen_string_literal: true

module StyleGuideAbTests
  class PromoteWinner
    RECOMPRESSION_SOURCE = "style_guide_ab_test_promotion"

    attr_reader :style_guide_ab_test

    def initialize(style_guide_ab_test:)
      @style_guide_ab_test = style_guide_ab_test
    end

    def self.call(...)
      new(...).promote
    end

    def promote
      validate!

      style_guide = style_guide_ab_test.style_guide
      winning_version = style_guide_ab_test.winner_variant.style_guide_version

      style_guide.with_lock do
        style_guide.update_columns(
          raw_content: winning_version.raw_content,
          compressed_content: nil,
          compression_metadata: { "raw_content_updated_at" => Time.current.iso8601 },
          current_version_id: winning_version.id,
          updated_at: Time.current
        )
      end

      StyleGuides::EnqueueCompression.call(style_guide:, source: RECOMPRESSION_SOURCE)

      winning_version
    end

    private

    def validate!
      raise ArgumentError, "A/B test is not completed" unless style_guide_ab_test.completed?
      raise ArgumentError, "A/B test has no winner" unless style_guide_ab_test.winner_variant
    end
  end
end
