# frozen_string_literal: true

module AbTests
  # Records a quality score for an A/B test assignment and updates variant aggregates.
  # Optionally checks for auto-completion if sufficient samples have been gathered.
  #
  # @example
  #   AbTests::RecordResult.call(agent_run: run, quality_score: 0.85)
  class RecordResult
    attr_reader :agent_run, :quality_score

    def initialize(agent_run:, quality_score:)
      @agent_run = agent_run
      @quality_score = quality_score
    end

    def self.call(...)
      new(...).record
    end

    def record
      assignment = AbTestAssignment.find_by(agent_run: agent_run)
      return unless assignment

      assignment.update!(quality_score: quality_score)
      assignment.ab_test_variant.record_quality_score!(quality_score)

      check_auto_completion(assignment.ab_test)
    end

    private

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
