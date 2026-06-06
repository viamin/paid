# frozen_string_literal: true

module Models
  module RunnerTierLookup
    private

    def runner_tier_model(tier)
      return nil unless tier

      model_id = agent_run.runner&.tier_model_ids&.dig(tier)
      return nil if model_id.blank?

      LlmModel.active.find_by(model_id: model_id)
    end

    def compatible_model_scope(scope)
      return scope.free if free_tier_constrained_runner?

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

    # openrouter_free is constrained to free-pricing models rather than a single
    # provider: it routes any active free model through OpenRouter, so selection
    # must stay within the free tier to match what execution actually pins.
    # Without this, selection treats the runner as unconstrained and can record
    # a paid candidate that execution later swaps for the runner's free model.
    def free_tier_constrained_runner?
      agent_run.runner&.runner_key == "openrouter_free"
    end

    def excluded_model?(model, excluded)
      excluded.is_a?(Array) && excluded.include?(model.model_id)
    end
  end
end
