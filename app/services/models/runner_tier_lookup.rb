# frozen_string_literal: true

module Models
  module RunnerTierLookup
    private

    def runner_tier_model(tier)
      return nil unless tier

      resolved = Runners::ResolveTierModel.call(
        runner: agent_run.runner,
        tier: tier,
        provider: agent_run.provider
      )
      model_id = resolved.model_id if resolved.success?
      model_id ||= agent_run.runner&.tier_model_ids&.dig(tier)
      return nil if model_id.blank?

      LlmModel.active.find_by(model_id: model_id)
    end

    def compatible_model_scope(scope)
      model_provider = compatible_model_provider
      return scope unless model_provider.present?

      scope.by_provider(model_provider)
    end

    def compatible_model_provider
      runner = agent_run.runner
      return nil unless runner

      runner.direct_outbound_llm_model_provider.presence ||
        Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key.to_s]
    end

    def excluded_model?(model, excluded)
      excluded.is_a?(Array) && excluded.include?(model.model_id)
    end
  end
end
