# frozen_string_literal: true

module Runners
  class FreeModelExecutionPlan
    include OpenRouterDataRouting

    Result = Struct.new(:config, keyword_init: true)

    OPENROUTER_PROVIDER_KEY = "openrouter"

    def self.call(...)
      new(...).call
    end

    def initialize(runner:, model_id:, project:)
      @runner = runner
      @model_id = model_id
      @project = project
    end

    # @spec FREE-MODEL-001
    def call
      raise ArgumentError, "OpenRouter API key required" if @runner.effective_api_secret.to_s.blank?
      unless @runner.required_api_service_type == OPENROUTER_PROVIDER_KEY
        raise ArgumentError,
          "#{@runner.runner_key} runner must use the OpenRouter API service type " \
          "(got #{@runner.required_api_service_type.inspect})"
      end

      privacy_policy = @runner.effective_privacy_policy(project: @project)
      unless privacy_policy.eligible
        raise AgentHarness::ConfigurationError,
          "The selected runner cannot enforce the required zero data retention policy before sending an OpenRouter request"
      end

      Result.new(
        config: {
          model: @model_id,
          base_url: Runner::DIRECT_OUTBOUND_API_PROVIDERS.fetch(OPENROUTER_PROVIDER_KEY).fetch(:base_url),
          api_key_env: "OPENROUTER_API_KEY",
          provider_routing: build_provider_routing(
            @project,
            zero_data_retention: privacy_policy.zdr_required
          )
        }
      )
    end
  end
end
