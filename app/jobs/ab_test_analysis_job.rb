# frozen_string_literal: true

class AbTestAnalysisJob < ApplicationJob
  queue_as :default

  def perform(ab_test_id)
    ab_test = AbTest.find(ab_test_id)
    return unless ab_test.running?

    result = AbTests::Analyze.call(ab_test: ab_test)

    if result.status == :winner_found
      ab_test.complete!(winner: result.winner)
      Rails.logger.info(
        message: "ab_test.auto_completed",
        ab_test_id: ab_test.id,
        winner_variant_id: result.winner&.id,
        confidence: result.confidence
      )
    end
  end
end
