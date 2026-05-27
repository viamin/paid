# frozen_string_literal: true

module Runners
  class DefaultTierModelIds
    # Static last-resort defaults used only when neither Runner#tier_models nor
    # Provider#tier_models provides an explicit model for the requested tier.
    RUNNER_KEY_TO_MODEL_PROVIDER = {
      "claude" => "anthropic",
      "cursor" => "anthropic",
      "aider" => "anthropic",
      "codex" => "openai",
      "gemini" => "google"
    }.freeze

    DIRECT_OUTBOUND_RUNNER_KEYS = %w[kilocode opencode pi].freeze

    def self.call(runner_key:)
      new(runner_key: runner_key).call
    end

    def initialize(runner_key:)
      @runner_key = runner_key.to_s
    end

    def call
      # Direct-outbound runners must be configured explicitly on the runner.
      # An empty hash here keeps the static map as a fallback-of-last-resort,
      # not a hidden source of truth for runner-tier resolution.
      model_provider = RUNNER_KEY_TO_MODEL_PROVIDER[@runner_key]
      return {} if model_provider.blank? && !DIRECT_OUTBOUND_RUNNER_KEYS.include?(@runner_key)

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
