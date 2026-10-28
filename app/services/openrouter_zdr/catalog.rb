# frozen_string_literal: true

module OpenrouterZdr
  class Catalog
    Result = Data.define(:models, :status)

    def self.call(project: nil)
      new(project:).call
    end

    # @spec FREE-MODEL-SYNC-014
    def initialize(project: nil)
      @project = project
    end

    def call
      Result.new(models: eligible_models, status: OpenrouterZdrCatalogStatus.current)
    end

    private

    attr_reader :project

    def eligible_models
      return LlmModel.none if project && !project.llm_provider_allowed?("openrouter")

      LlmModel.active.openrouter_zdr_eligible.by_capability
    end
  end
end
