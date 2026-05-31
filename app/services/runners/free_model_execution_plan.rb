# frozen_string_literal: true

module Runners
  class FreeModelExecutionPlan
    Result = Struct.new(:config, keyword_init: true)

    DEFAULT_DATA_CLASSIFICATION = "internal"
    OPENROUTER_PROVIDER_KEY = "openrouter"

    def self.call(...)
      new(...).call
    end

    def initialize(runner:, model_id:, project:)
      @runner = runner
      @model_id = model_id
      @project = project
    end

    def call
      raise ArgumentError, "OpenRouter API key required" if @runner.effective_api_secret.to_s.blank?
      raise ArgumentError, "OpenRouter API key required" unless @runner.required_api_service_type == OPENROUTER_PROVIDER_KEY

      Result.new(
        config: {
          model: @model_id,
          base_url: Runner::DIRECT_OUTBOUND_API_PROVIDERS.fetch(OPENROUTER_PROVIDER_KEY).fetch(:base_url),
          api_key_env: "OPENROUTER_API_KEY",
          provider_routing: build_provider_routing(@project)
        }
      )
    end

    def build_provider_routing(project)
      case data_classification_for(project)
      when "open", "internal"
        { data_collection: "allow" }
      when "confidential"
        { data_collection: "deny" }
      when "restricted"
        { data_collection: "deny", zdr: true }
      else
        { data_collection: "allow" }
      end
    end

    private

    def data_classification_for(project)
      return DEFAULT_DATA_CLASSIFICATION unless project&.respond_to?(:data_classification)

      project.data_classification.presence || DEFAULT_DATA_CLASSIFICATION
    end
  end
end
