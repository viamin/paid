# frozen_string_literal: true

module Providers
  # Returns a sensible default {tier => model_id} mapping for a provider_key.
  # Used to seed Provider#tier_model_ids on create and as a fallback when a
  # provider has not been explicitly configured.
  class DefaultTierModelIds
    # Maps a Paid provider_key to the LlmModel.provider value its API talks to.
    PROVIDER_KEY_TO_MODEL_PROVIDER = {
      "claude" => "anthropic",
      "cursor" => "anthropic",
      "aider" => "anthropic",
      "codex" => "openai",
      "gemini" => "google"
    }.freeze

    def self.call(provider_key:)
      new(provider_key: provider_key).call
    end

    def initialize(provider_key:)
      @provider_key = provider_key.to_s
    end

    def call
      model_provider = PROVIDER_KEY_TO_MODEL_PROVIDER[@provider_key]
      return {} if model_provider.blank?

      LlmModel::TIERS.each_with_object({}) do |tier, mapping|
        model = LlmModel.active.by_provider(model_provider).by_tier(tier).by_capability.first
        mapping[tier] = model.model_id if model
      end
    end
  end
end
