# frozen_string_literal: true

module Runners
  class ParetoExecutionPlan
    include OpenRouterDataRouting

    Result = Struct.new(:config, keyword_init: true)

    OPENROUTER_PROVIDER_KEY = "openrouter"
    PARETO_MODEL_ID = "openrouter/pareto-code"

    def self.call(...)
      new(...).call
    end

    def initialize(runner:, project:)
      @runner = runner
      @project = project
    end

    def call
      raise ArgumentError, "OpenRouter API key required" if @runner.effective_api_secret.to_s.blank?
      unless @runner.required_api_service_type == OPENROUTER_PROVIDER_KEY
        raise ArgumentError,
          "openrouter_pareto runner must use the OpenRouter API service type " \
          "(got #{@runner.required_api_service_type.inspect})"
      end

      Result.new(
        config: {
          model: PARETO_MODEL_ID,
          base_url: Runner::DIRECT_OUTBOUND_API_PROVIDERS.fetch(OPENROUTER_PROVIDER_KEY).fetch(:base_url),
          api_key_env: "OPENROUTER_API_KEY",
          provider_routing: build_provider_routing(@project)
        }
      )
    end
  end
end
