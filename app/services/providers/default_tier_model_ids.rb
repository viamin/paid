# frozen_string_literal: true

module Providers
  class DefaultTierModelIds
    PROVIDER_KEY_TO_MODEL_PROVIDER = {
      "claude" => "anthropic",
      "cursor" => "anthropic",
      "codex" => "openai",
      "gemini" => "google"
    }.freeze

    DIRECT_OUTBOUND_PROVIDER_KEYS = %w[kilocode opencode].freeze

    def self.call(provider_key:)
      new(provider_key: provider_key).call
    end

    def initialize(provider_key:)
      @provider_key = provider_key.to_s
    end

    def call
      model_provider = PROVIDER_KEY_TO_MODEL_PROVIDER[@provider_key]
      return {} if model_provider.blank? && !DIRECT_OUTBOUND_PROVIDER_KEYS.include?(@provider_key)

      if model_provider
        tier_defaults_for_standard_provider(model_provider)
      else
        {}
      end
    end

    private

    def tier_defaults_for_standard_provider(model_provider)
      LlmModel::TIERS.each_with_object({}) do |tier, mapping|
        model = LlmModel.active.by_provider(model_provider).by_tier(tier).by_capability.first
        mapping[tier] = model.model_id if model
      end
    end
  end
end
