# frozen_string_literal: true

module OpenrouterZdr
  class EligibleModels
    def self.call(...)
      new(...).call
    end

    # @spec FREE-MODEL-SYNC-012
    def self.freshness
      OpenrouterZdrCatalogRefresh.current
    end

    def initialize(project:, runner_key:, auth_type:)
      @project = project
      @runner_key = runner_key
      @auth_type = auth_type
    end

    # @spec FREE-MODEL-SYNC-013
    def call
      LlmModel.active.where(openrouter_zdr_eligible: true).by_capability.select do |model|
        project.llm_provider_allowed?(model.provider) && compatible?(model)
      end
    end

    private

    attr_reader :project, :runner_key, :auth_type

    def compatible?(model)
      !Runners::ModelCompatibility.call(
        runner_key: runner_key,
        model_id: model.model_id,
        auth_type: auth_type,
        llm_model: model
      ).unsupported?
    end
  end
end
