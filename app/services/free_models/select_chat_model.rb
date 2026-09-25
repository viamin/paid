# frozen_string_literal: true

module FreeModels
  class SelectChatModel
    def self.call(...)
      new(...).call
    end

    def initialize(runner:, project: nil, preferred_model_id: nil)
      @runner = runner
      @project = project
      @preferred_model_id = preferred_model_id
    end

    # @spec CHAT-API-018, MODEL-POLICY-013
    def call
      candidates = eligible_models
      candidates.find { |model| model.model_id == @preferred_model_id } || candidates.first ||
        raise(ChatSessions::LlmClientConfigurationError,
          "No eligible OpenRouter free chat model is available. Check the daily catalog sync, project restrictions, and model rate limits.")
    end

    private

    def eligible_models
      excluded = Array(@project&.model_preferences&.dig("excluded_free_model_ids"))
      limited = @runner.user.runner_states.find_by(runner_name: @runner.state_key)&.rate_limited_model_ids || Set.new

      LlmModel.openrouter_synced_free.active.by_capability.order(:model_id).select do |model|
        model.operator_active_override != false && !model.expired? && !model.below_quality_bar? &&
          !model.model_id.start_with?("openrouter/") &&
          !QualityFilter.call(context_window: model.context_window, supports_tools: model.supports_tools) &&
          Array(model.metadata.dig("architecture", "output_modalities")).include?("text") &&
          !excluded.include?(model.model_id) && !limited.include?(model.model_id) &&
          (!@project || @project.llm_provider_allowed?(model.provider))
      end
    end
  end
end
