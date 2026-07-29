# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class SensitiveDataFreeModel < HealthChecks::Check
        self.scope = :project

        def self.network? = false

        def call
          model = resolved_model
          return [] unless sensitive_project?
          return [] unless model&.free?
          return [] unless model.data_training_risk == "possible"
          return [] if openrouter_routed?(model)

          finding(
            severity: :warning,
            message: "Sensitive project resolves to free model #{model.model_id} with possible training risk."
          )
        end

        private

        def resolved_model
          required_model || preferred_model || tenant_preferred_model
        end

        def required_model
          model_id = model_preferences["required_model_id"]
          return if model_id.blank?

          LlmModel.active.find_by(model_id: model_id)
        end

        def preferred_model
          model_ids = model_preferences["preferred_model_ids"]
          return unless model_ids.is_a?(Array)

          models_by_id = LlmModel.active.where(model_id: model_ids).index_by(&:model_id)
          model_ids
            .map { |model_id| models_by_id[model_id] }
            .compact
            .find { |model| subject.llm_provider_allowed?(model.provider) }
        end

        def tenant_preferred_model
          model_id = subject.account.tenant_setting&.model_preference_for(create_pr_runner_key)
          return if model_id.blank?

          model = LlmModel.active.find_by(model_id: model_id)
          return unless model
          return unless subject.llm_provider_allowed?(model.provider)

          model
        end

        def model_preferences
          @model_preferences ||= begin
            raw = subject.model_preferences
            raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
          end
        end

        def sensitive_project?
          subject.confidential? || subject.restricted?
        end

        def openrouter_routed?(model)
          preferred_agent_type_openrouter? || create_pr_runner_openrouter? || model.catalog_source == "openrouter_sync"
        end

        def preferred_agent_type_openrouter?
          %w[openrouter_free openrouter_pareto].include?(model_preferences["preferred_agent_type"])
        end

        def create_pr_runner_openrouter?
          %w[openrouter_free openrouter_pareto].include?(create_pr_runner_key)
        end

        # Health checks run without an AgentRun, so mirror the runtime
        # create_pr selection entry point on a duplicated settings record. This
        # keeps round-robin/random routing aligned with RunnerResolver without
        # mutating persisted selection state during a local check.
        def create_pr_runner_key
          identifier = create_pr_runner_identifier
          return if identifier.blank?

          owner = subject.effective_owner
          runner = Runner.for_identifier(owner, identifier) if owner
          runner&.runner_key || identifier
        end

        def create_pr_runner_identifier
          settings = AgentRuns::UserSettingsResolver.call(project: subject, strict: false)
          return if settings.blank?

          settings.dup.select_automated_runner_identifier(goal: "create_pr") ||
            settings.default_runner_identifier_for_goal("create_pr")
        end
      end
    end
  end
end
