# frozen_string_literal: true

module DesignAmendments
  # Abandons a design amendment (rejected or closed-unmerged design PR): the
  # feature returns to `released` under the prior approved revision and no
  # impact is evaluated.
  # @spec INTENT-AMENDMENT-004
  class Abandon
    def self.call(...)
      new(...).call
    end

    def initialize(amendment:)
      @amendment = amendment
    end

    def call
      unless amendment.status.in?(%w[open approved])
        raise InvalidTransitionError, "cannot abandon a #{amendment.status} amendment"
      end

      amendment.transaction(requires_new: true) do
        amendment.update!(status: "abandoned")
        amendment.feature_intent.release!
      end
      amendment
    end

    private

    attr_reader :amendment
  end
end
