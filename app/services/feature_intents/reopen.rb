# frozen_string_literal: true

module FeatureIntents
  # @spec FEATURE-APPROVAL-020
  class Reopen
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, actor:)
      @feature_intent = feature_intent
      @actor = actor
    end

    def call
      raise NotAuthorizedError unless FeatureIntentPolicy.new(actor, feature_intent).reopen?

      feature_intent.reopen!(by: actor).tap { log_reopen }
    end

    private

    attr_reader :feature_intent, :actor

    def log_reopen
      Rails.logger.info(message: "feature_intents.reopen", feature_intent_id: feature_intent.id, project_id: feature_intent.project_id,
        reopened_by_id: actor.id)
    end

    class NotAuthorizedError < StandardError; end
  end
end
