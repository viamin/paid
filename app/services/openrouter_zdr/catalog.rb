# frozen_string_literal: true

module OpenrouterZdr
  class Catalog
    Freshness = Data.define(:available?, :successful?, :last_attempted_at, :last_successful_at, :error_message)

    def self.eligible_models(...)
      new(...).eligible_models
    end

    def self.freshness
      refresh = OpenrouterZdrCatalogRefresh.find_by(catalog_name: OpenrouterZdrCatalogRefresh::CATALOG_NAME)
      return Freshness.new(available?: false, successful?: false, last_attempted_at: nil, last_successful_at: nil, error_message: nil) unless refresh

      Freshness.new(
        available?: refresh.status == "successful",
        successful?: refresh.last_successful_at.present?,
        last_attempted_at: refresh.last_attempted_at,
        last_successful_at: refresh.last_successful_at,
        error_message: refresh.error_message
      )
    end

    def initialize(runner_key: nil, auth_type: "api_key", project: nil)
      @runner_key = runner_key
      @auth_type = auth_type
      @project = project
    end

    # @spec FREE-MODEL-SYNC-012
    def eligible_models
      models = LlmModel.active.openrouter_zdr_eligible.by_capability.to_a
      models = models.select { |model| project.llm_provider_allowed?(model.provider) } if project
      return models unless runner_key

      models.reject { |model| Runners::ModelCompatibility.call(runner_key:, model_id: model.model_id, auth_type:, llm_model: model).unsupported? }
    end

    private

    attr_reader :runner_key, :auth_type, :project
  end
end
