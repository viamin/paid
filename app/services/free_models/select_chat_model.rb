# frozen_string_literal: true

module FreeModels
  class SelectChatModel
    def self.call(...)
      new(...).call
    end

    # @spec CHAT-API-019
    def self.for_session(runner:, chat_session:, transport: :api)
      projects = chat_session.llm_policy_projects
      sensitive = projects.any? { |project| project.confidential? || project.restricted? }
      if sensitive && (transport == :api || %w[pi omp].include?(runner.runner_key))
        raise ChatSessions::LlmClientConfigurationError,
          "This free chat runner cannot enforce the required OpenRouter privacy routing for confidential or restricted project context. Choose a chat provider approved for the project's privacy requirements."
      end

      call(runner: runner, projects: projects, preferred_model_id: chat_session.model)
    end

    def initialize(runner:, project: nil, projects: [], preferred_model_id: nil)
      @runner = runner
      @projects = (projects + [ project ]).compact.uniq
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
      excluded = @projects.flat_map { |project| Array(project.model_preferences&.dig("excluded_free_model_ids")) }
      limited = @runner.user.runner_states.find_by(runner_name: @runner.state_key)&.rate_limited_model_ids || Set.new

      LlmModel.openrouter_synced_free.active.by_capability.order(:model_id).select do |model|
        model.operator_active_override != false && !model.expired? && !model.below_quality_bar? &&
          !model.model_id.start_with?("openrouter/") &&
          !QualityFilter.call(context_window: model.context_window, supports_tools: model.supports_tools) &&
          Array(model.metadata.dig("architecture", "output_modalities")).include?("text") &&
          !excluded.include?(model.model_id) && !limited.include?(model.model_id) &&
          @projects.all? { |project| project.llm_provider_allowed?(model.provider) }
      end
    end
  end
end
