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
      scoped = if free_tier_constrained_runner?
        scope.free
      else
        model_provider = compatible_model_provider
        model_provider.present? ? scope.by_provider(model_provider) : scope
      end
      apply_project_llm_provider_routing(scoped)
    end

    # Narrows a model scope to the LLM providers the project permits via its
    # per-project allowlist/blocklist (model_preferences["llm_providers"]).
    # Returns the scope unchanged when the project has no restriction.
    def apply_project_llm_provider_routing(scope)
      project = agent_run.project
      return scope unless project.llm_provider_routing_restricted?

      allowlist = project.llm_provider_allowlist
      return scope.where(provider: allowlist) if allowlist.any?

      scope.where.not(provider: project.llm_provider_blocklist)
    end

    def compatible_model_provider
      runner = agent_run.runner
      return nil unless runner

      runner.direct_outbound_llm_model_provider.presence ||
        Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key.to_s]
    end

    # Free-policy runners are constrained to free-pricing models rather than a
    # single provider: they route any active free model through OpenRouter, so
    # selection must stay within the free tier to match what execution actually
    # pins. Without this, selection treats the runner as unconstrained and can
    # record a paid candidate that execution later swaps for the runner's free
    # model.
    def free_tier_constrained_runner?
      agent_run.runner&.free_model_policy?
    end

    def excluded_model?(model, excluded)
      excluded.is_a?(Array) && excluded.include?(model.model_id)
    end
  end
end
