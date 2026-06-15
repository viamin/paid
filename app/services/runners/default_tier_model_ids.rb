# frozen_string_literal: true

module Runners
  class DefaultTierModelIds
    RUNNER_KEY_TO_MODEL_PROVIDER = {
      "claude" => "anthropic",
      "cursor" => "anthropic",
      "aider" => "anthropic",
      "codex" => "openai",
      "gemini" => "google"
    }.freeze

    DIRECT_OUTBOUND_RUNNER_KEYS = %w[kilocode opencode openrouter_free pi].freeze

    def self.call(runner_key:)
      new(runner_key: runner_key).call
    end

    def initialize(runner_key:)
      @runner_key = runner_key.to_s
    end

    def call
      return tier_defaults_for_openrouter_free if @runner_key == Runner::OPENROUTER_FREE_RUNNER_KEY

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
        model = LlmModel.active.by_provider(model_provider).by_tier(tier).by_capability
          .find { |m| runner_model_compatible?(m.model_id) }
        mapping[tier] = model.model_id if model
      end
    end

    def runner_model_compatible?(model_id)
      result = ModelCompatibility.call(
        runner_key: @runner_key,
        model_id: model_id,
        auth_type: "api_key"
      )
      if result.unsupported?
        Rails.logger.info(
          message: "model_selection.default_model_filtered_incompatible",
          runner_key: @runner_key,
          model_id: model_id,
          incompatibility_type: result.incompatibility_type,
          reason: result.reason
        )
      end
      !result.unsupported?
    end

    def tier_defaults_for_openrouter_free
      models = LlmModel.free.active.by_provider(Runner::OPENROUTER_FREE_MODEL_PROVIDER).by_capability.to_a.reject(&:below_quality_bar?)

      LlmModel::TIERS.each_with_object({}) do |tier, mapping|
        model = models.find { |entry| entry.tier == tier }
        mapping[tier] = model.model_id if model
      end
    end
  end
end
