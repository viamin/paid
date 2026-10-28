# frozen_string_literal: true

module OpenrouterZdr
  class EligibleModels
    def self.call
      LlmModel.active.joins("INNER JOIN openrouter_zdr_eligibilities ON openrouter_zdr_eligibilities.model_id = llm_models.model_id")
        .merge(OpenrouterZdrEligibility.active)
    end
  end
end
