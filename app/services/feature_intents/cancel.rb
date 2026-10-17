# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-020
  class Cancel
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, actor:, cancellation_reason: nil, replacement_reference: nil)
      @feature_intent = feature_intent
      @actor = actor
      @cancellation_reason = cancellation_reason
      @replacement_reference = replacement_reference
    end

    def call
      raise NotAuthorizedError unless FeatureIntentPolicy.new(actor, feature_intent).cancel?
      raise InvalidCancellationError, "Select why this proposal is being declined." unless cancellation_reason.in?(FeatureIntent::CANCELLATION_REASONS)

      feature_intent.cancel!(by: actor, reason: cancellation_reason, replacement_reference: replacement_reference).tap { log_cancellation }
    rescue ActiveRecord::RecordInvalid => error
      raise InvalidCancellationError, error.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :feature_intent, :actor, :cancellation_reason, :replacement_reference

    def log_cancellation
      Rails.logger.info(message: "feature_intents.cancel", feature_intent_id: feature_intent.id, project_id: feature_intent.project_id,
        cancelled_by_id: actor.id, reason: cancellation_reason)
    end

    class NotAuthorizedError < StandardError; end
    class InvalidCancellationError < StandardError; end
  end
end
