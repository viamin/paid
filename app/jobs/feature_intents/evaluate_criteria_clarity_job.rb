# frozen_string_literal: true

module FeatureIntents
  # Runs the AI-assisted acceptance-criteria clarity check out-of-band and
  # caches the verdict (RDR-066 readiness). Enqueued whenever something that
  # could change the verdict happens — a feature intent decision resolves —
  # rather than on Inbox render.
  # @spec FEATURE-APPROVAL-011
  class EvaluateCriteriaClarityJob < ApplicationJob
    queue_as :low_priority

    discard_on ActiveRecord::RecordNotFound

    def perform(feature_intent_id:)
      feature_intent = FeatureIntent.find(feature_intent_id)
      FeatureIntents::EvaluateCriteriaClarity.call(feature_intent: feature_intent)
    end
  end
end
