# frozen_string_literal: true

module OpenrouterZdr
  class EligibleModels
    Result = Data.define(:models, :catalog)

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-013
    def call
      Result.new(models: LlmModel.active.where(model_id: OpenrouterZdrModel.select(:model_id)),
        catalog: OpenrouterZdrCatalog.current)
    end
  end
end
