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

      score_recorded = ActiveRecord::Base.transaction do
        # Use a conditional UPDATE to atomically claim the assignment, preventing
        # double-counting if two processes record the same agent_run concurrently.
        updated_count = AbTestAssignment
          .where(ab_test: ab_test, agent_run: agent_run, quality_score: nil)
          .update_all(quality_score: quality_score, updated_at: Time.current)
        next false unless updated_count > 0

        assignment = AbTestAssignment.find_by!(ab_test: ab_test, agent_run: agent_run)
        assignment.ab_test_variant.record_quality_score!(quality_score)
        true
      end

      check_auto_completion(ab_test) if score_recorded
    end

    private

    def validate_quality_score!
      unless quality_score.is_a?(Numeric) && quality_score >= 0 && quality_score <= 1
        raise ArgumentError, "quality_score must be a number between 0 and 1"
      end
    end

    # Throttle analysis to avoid running the full t-test on every single sample.
    # Only analyze when total samples are a multiple of ANALYSIS_INTERVAL, or when
    # min_samples_per_variant is first reached.
    ANALYSIS_INTERVAL = 5

    def check_auto_completion(ab_test)
      ab_test.reload
      return unless ab_test.running?
      return unless ab_test.sufficient_samples?
      return unless should_analyze?(ab_test)

      result = ab_test.cached_or_compute_analysis
      return if result.status == :insufficient_data

      if result.status == :winner_found
        ab_test.complete!(winner: result.winner)
      elsif result.status == :control_wins
        ab_test.complete!
      end
    rescue ActiveRecord::RecordInvalid
      # Another process already completed or cancelled this test concurrently.
      # The complete! method uses with_lock { reload } internally, but two processes
      # can still race past the running? check above. Treat as a no-op.
      nil
    end

    def should_analyze?(ab_test)
      total_samples = ab_test.ab_test_variants.sum(:sample_count)
      min_required = ab_test.min_samples_per_variant * ab_test.ab_test_variants.count
      total_samples == min_required || (total_samples % ANALYSIS_INTERVAL).zero?
    end
  end
end
