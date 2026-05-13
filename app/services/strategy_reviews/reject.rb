# frozen_string_literal: true

module StrategyReviews
  class Reject
    attr_reader :strategy_version, :reviewer

    def initialize(strategy_version:, reviewer:)
      @strategy_version = strategy_version
      @reviewer = reviewer
    end

    def self.call(...)
      new(...).reject
    end

    def reject
      validate!

      strategy_version.strategy.with_lock do
        raise ArgumentError, "strategy version is no longer pending review" unless strategy_version.reload.pending_review?

        strategy_version.update!(promotion_state: "rejected")
      end

      strategy_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "strategy version is not pending review" unless strategy_version.pending_review?
    end
  end
end
