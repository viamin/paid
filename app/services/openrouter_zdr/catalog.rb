# frozen_string_literal: true

module OpenrouterZdr
  class Catalog
    Result = Data.define(:models, :freshness) do
      def available?
        freshness.available?
      end
    end

    def self.call(project: nil, runner_key: nil, auth_type: nil)
      new(project:, runner_key:, auth_type:).call
    end

    def initialize(project: nil, runner_key: nil, auth_type: nil)
      @project = project
      @runner_key = runner_key
      @auth_type = auth_type
    end

    # @spec OPENROUTER-ZDR-007
    def call
      Result.new(models: filtered_models, freshness: OpenrouterZdrSync.current)
    end

    private

    attr_reader :project, :runner_key, :auth_type

    def filtered_models
      scope = LlmModel.active.openrouter_zdr_eligible.by_capability
      scope = scope.where(provider: project.llm_provider_allowlist) if project&.llm_provider_allowlist&.any?
      scope = scope.where.not(provider: project.llm_provider_blocklist) if project&.llm_provider_blocklist&.any?
      return scope unless runner_key.present? && auth_type.present?

      scope.select do |model|
        !Runners::ModelCompatibility.call(
          runner_key:, model_id: model.model_id, auth_type:, llm_model: model
        ).unsupported?
      end
    end
  end
end
