# frozen_string_literal: true

module Models
  class Select
    attr_reader :agent_run

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      selected = select_model
      return nil unless selected

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

      ModelSelection.create!(
        agent_run: agent_run,
        llm_model: selected[:model],
        selector_type: selected[:selector_type],
        reasoning: selected[:reasoning],
        candidates: selected[:candidates],
        complexity_score: selected[:complexity_score],
        selection_duration_ms: duration_ms
      )
    end

    private

    def select_model
      project = agent_run.project

      # Check for project-level model override
      if project.model_preferences["required_model_id"].present?
        model = LlmModel.active.find_by(model_id: project.model_preferences["required_model_id"])
        return override_result(model, "Project requires specific model") if model
      end

      # Use rules-based selection
      Models::RulesBasedSelector.call(agent_run: agent_run)
    end

    def override_result(model, reason)
      {
        model: model,
        selector_type: "override",
        reasoning: reason,
        candidates: [ { model_id: model.model_id, score: model.capability_score } ],
        complexity_score: nil
      }
    end
  end
end
