# frozen_string_literal: true

module FeatureIntents
  # Runs CriteriaClarityReview and persists the verdict onto the feature
  # intent (RDR-066 readiness). Kept out-of-band from Inbox rendering:
  # callers enqueue EvaluateCriteriaClarityJob when something that could
  # change the verdict happens (a decision resolves, the brief or linked
  # issues change), not on every read.
  # @spec FEATURE-APPROVAL-006
  class EvaluateCriteriaClarity
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      review = CriteriaClarityReview.call(feature_intent: feature_intent)

      # Failure (nil) fails closed: recorded as "vague" so approval stays
      # blocked until a successful review confirms the criteria are clear.
      feature_intent.record_criteria_clarity!(
        state: review&.clear? ? "clear" : "vague",
        explanation: review&.explanation.presence || "Acceptance criteria clarity could not be confirmed."
      )
    end

    private

    attr_reader :feature_intent
  end
end
