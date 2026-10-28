# frozen_string_literal: true

module OpenrouterZdr
  class Catalog
    Result = Data.define(:models, :refresh)

    def self.call(...)
      new(...).call
    end

    def initialize(project: nil, runner_key: nil, auth_type: nil)
      @project = project
      @runner_key = runner_key
      @auth_type = auth_type
    end

    # @spec FREE-MODEL-SYNC-013
    def call
      Result.new(models: compatible_models, refresh: OpenrouterZdrRefresh.current)
    end

    private

    attr_reader :project, :runner_key, :auth_type

    def compatible_models
      candidate_models.select { |model| provider_allowed?(model) && runner_compatible?(model) }
    end

    def candidate_models
      LlmModel.active.openrouter_zdr_eligible.order(Arel.sql("capability_score DESC NULLS LAST"), :display_name).to_a
    end

    def provider_allowed?(model)
      project.nil? || project.llm_provider_allowed?(model.provider)
    end

    def runner_compatible?(model)
      return true if runner_key.blank?

      !Runners::ModelCompatibility.call(
        runner_key: runner_key,
        model_id: model.model_id,
        auth_type: auth_type,
        llm_model: model
      ).unsupported?
    end
  end
end
