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

    def excluded_model?(model, excluded)
      excluded.is_a?(Array) && excluded.include?(model.model_id)
    end
  end
end
