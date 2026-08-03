# frozen_string_literal: true

module FreeModels
  class DefaultTierModels
    def self.call
      new.call
    end

    # @spec FREE-MODEL-RUNNER-001
    def call
      eligible_models_by_tier.each_with_object({}) do |(tier, models), mapping|
        best_model = models.max_by { |model| model.capability_score.to_f }
        mapping[tier] = best_model.model_id if best_model
      end
    end

    private

    def eligible_models_by_tier
      LlmModel.openrouter_synced_free.active.where(tier: LlmModel::TIERS)
        .reject(&:below_quality_bar?)
        .group_by(&:tier)
    end
  end
end
