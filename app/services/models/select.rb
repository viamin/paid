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

      ModelSelection.find_or_create_by!(agent_run: agent_run) do |ms|
        ms.llm_model = selected[:model]
        ms.selector_type = selected[:selector_type]
        ms.reasoning = selected[:reasoning]
        ms.candidates = selected[:candidates]
        ms.complexity_score = selected[:complexity_score]
        ms.tier = selected[:tier] || tier_for(selected)
        ms.selection_duration_ms = duration_ms
      end
    rescue ActiveRecord::RecordNotUnique
      ModelSelection.find_by!(agent_run: agent_run)
    end

    private

    def select_model
      project = agent_run.project

      # Check for project-level model override
      if project.model_preferences["required_model_id"].present?
        model = LlmModel.active.find_by(model_id: project.model_preferences["required_model_id"])
        return override_result(model, "Project requires specific model") if model
      end

      quality_escalation = quality_escalation_result(project)
      return quality_escalation if quality_escalation

      # Check for preferred models
      preferred = preferred_model_result(project)
      return preferred if preferred

      tenant_preferred = tenant_model_preference_result(project)
      return tenant_preferred if tenant_preferred

      # Try meta-agent selection, fall back to rules-based
      Models::MetaAgentSelector.call(agent_run: agent_run) ||
        Models::RulesBasedSelector.call(agent_run: agent_run)
    end

    def quality_escalation_result(project)
      tier = QualityRecovery::ModelEscalation.target_tier(project)
      return nil unless tier

      model = LlmModel.active.by_tier(tier).by_capability.first
      return nil unless model

      {
        model: model,
        selector_type: "quality_escalation",
        reasoning: "Quality-triggered escalation to #{tier} tier",
        candidates: [ { model_id: model.model_id, score: model.capability_score.to_f } ],
        complexity_score: nil,
        tier: tier
      }
    end

    def preferred_model_result(project)
      preferred_ids = project.model_preferences["preferred_model_ids"]
      return nil unless preferred_ids.is_a?(Array) && preferred_ids.any?

      # Respect preference list ordering: select the first active model in the provided order
      models_by_id = LlmModel.active.where(model_id: preferred_ids).index_by(&:model_id)
      model = preferred_ids.map { |id| models_by_id[id] }.compact.first
      return nil unless model

      override_result(model, "Project preferred model: #{model.display_name}")
    end

    def tenant_model_preference_result(project)
      model_id = project.account.tenant_setting&.model_preference_for(agent_run.effective_provider)
      return nil if model_id.blank?

      model = LlmModel.active.find_by(model_id: model_id)
      return nil unless model

      override_result(model, "Tenant preferred model: #{model.display_name}")
    end

    def override_result(model, reason)
      {
        model: model,
        selector_type: "override",
        reasoning: reason,
        candidates: [ { model_id: model.model_id, score: model.capability_score.to_f } ],
        complexity_score: nil,
        # For override paths the tier follows the chosen model directly, since
        # no complexity-based routing was performed.
        tier: model.tier
      }
    end

    # Recorded tier for a selection. Prefers the selector's own tier (derived
    # from the complexity->tier mapping it used) and falls back to the model's
    # own tier so ModelSelection.tier is populated for every run, even when the
    # complexity score is absent (override paths).
    def tier_for(selected)
      return nil if selected.blank?

      selected[:tier].presence || selected[:model]&.tier
    end
  end
end
