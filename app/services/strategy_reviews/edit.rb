# frozen_string_literal: true

module StrategyReviews
  class Edit
    attr_reader :strategy_version, :reviewer, :attributes

    def initialize(strategy_version:, reviewer:, attributes:)
      @strategy_version = strategy_version
      @reviewer = reviewer
      @attributes = attributes || {}
    end

    def self.call(...)
      new(...).edit
    end

    def edit
      validate!

      new_version = nil
      strategy = strategy_version.strategy

      strategy.with_lock do
        raise ArgumentError, "strategy version is no longer pending review" unless strategy_version.reload.pending_review?

        new_version = strategy.create_pending_version!(
          content: attributes.fetch(:content, strategy_version.content),
          provenance: strategy_version.provenance,
          reasoning: attributes[:reasoning].presence || strategy_version.reasoning,
          change_notes: attributes[:change_notes].presence ||
            "Reviewer-edited variant of v#{strategy_version.version}",
          created_by: "reviewer",
          created_by_user: reviewer,
          parent_version: strategy_version
        )
        strategy_version.update!(promotion_state: "rejected")
      end

      new_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "strategy version is not pending review" unless strategy_version.pending_review?
      content = attributes[:content]
      raise ArgumentError, "content must be an object" unless content.is_a?(Hash)
    end
  end
end
