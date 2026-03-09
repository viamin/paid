# frozen_string_literal: true

module AbTests
  # Records a quality score for an A/B test assignment and updates variant aggregates.
  # Optionally checks for auto-completion if sufficient samples have been gathered.
  #
  # @example
  #   AbTests::RecordResult.call(ab_test: test, agent_run: run, quality_score: 0.85)
  class RecordResult
    attr_reader :ab_test, :agent_run, :quality_score

    def initialize(ab_test:, agent_run:, quality_score:)
      @ab_test = ab_test
      @agent_run = agent_run
      @quality_score = quality_score
    end

    def self.call(...)
      new(...).record
    end

    def record
      validate_quality_score!

      assignment = AbTestAssignment.find_by(ab_test: ab_test, agent_run: agent_run, quality_score: nil)
      return unless assignment

      assignment.update!(quality_score: quality_score)
      assignment.ab_test_variant.record_quality_score!(quality_score)

      check_auto_completion(ab_test)
    end

    private

    def validate_quality_score!
      unless quality_score.is_a?(Numeric) && quality_score >= 0 && quality_score <= 1
        raise ArgumentError, "quality_score must be a number between 0 and 1"
      end
    end

    def check_auto_completion(ab_test)
      return unless ab_test.running?
      return unless ab_test.sufficient_samples?

      result = AbTests::Analyze.call(ab_test: ab_test)
      return if result.status == :insufficient_data

      if result.status == :winner_found
        ab_test.complete!(winner: result.winner)
      elsif result.status == :control_wins
        ab_test.complete!
      end
    end
  end
end
