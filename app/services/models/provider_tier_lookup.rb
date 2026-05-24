# frozen_string_literal: true

module Models
  # Shared helpers for resolving provider-specific tier models and checking
  # project-level model exclusions. Included by Select, RulesBasedSelector,
  # and MetaAgentSelector to keep the logic in one place.
  module ProviderTierLookup
    private

    def provider_tier_model(tier)
      return nil unless tier

      model_id = agent_run.provider&.tier_models&.dig(tier, "model_id")
      model_id ||= agent_run.provider&.tier_model_ids&.dig(tier)
      return nil if model_id.blank?

      LlmModel.active.find_by(model_id: model_id)
    end

    def compatible_model_scope(scope)
      model_provider = compatible_model_provider
      return scope unless model_provider.present?

      scope.by_provider(model_provider)
    end

    def compatible_model_provider
      provider_key = agent_run.provider&.provider_key.to_s
      return nil if provider_key.blank?

      Providers::DefaultTierModelIds::PROVIDER_KEY_TO_MODEL_PROVIDER[provider_key]
    end

    def excluded_model?(model, excluded)
      excluded.is_a?(Array) && excluded.include?(model.model_id)
    end
  end
end
