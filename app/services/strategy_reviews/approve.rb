# frozen_string_literal: true

module StrategyReviews
  class Approve
    attr_reader :strategy_version, :reviewer

    def initialize(strategy_version:, reviewer:)
      @strategy_version = strategy_version
      @reviewer = reviewer
    end

    def self.call(...)
      new(...).approve
    end

    def approve
      validate!

      strategy = strategy_version.strategy
      approved_at = Time.current

      strategy.with_lock do
        raise ArgumentError, "strategy version is no longer pending review" unless strategy_version.reload.pending_review?

        retire_current_version!(strategy:, approved_at:)

        strategy_version.update!(
          promotion_state: "active",
          promoted_by_user: reviewer,
          promoted_at: approved_at,
          retired_at: nil
        )
        strategy.update!(current_version: strategy_version, status: "active")
      end

      strategy_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "strategy version is not pending review" unless strategy_version.pending_review?
    end

    def retire_current_version!(strategy:, approved_at:)
      current_version = strategy.current_version
      return if current_version.nil? || current_version == strategy_version

      current_version.update!(
        promotion_state: "retired",
        retired_at: approved_at
      )
    end
  end
end
