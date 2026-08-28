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
            title: "Sensitive project resolves to a data-training-risk model",
            description: "This sensitive project resolves to the free model #{model.model_id}, which may share data with the provider.",
            remediation: "Pin a non-free model or route this project's model through OpenRouter.",
            action_url: nil,
            metadata: { model_id: model.model_id }
          )
        end

        private

        def resolved_model
          required_model || preferred_model || tenant_preferred_model
        end

        def required_model
          model_id = model_preferences["required_model_id"]
          return if model_id.blank?

          selectable_override_model(LlmModel.active.find_by(model_id: model_id))
        end

        def preferred_model
          model_ids = model_preferences["preferred_model_ids"]
          return unless model_ids.is_a?(Array)

          models_by_id = LlmModel.active.where(model_id: model_ids).index_by(&:model_id)
          model_ids
            .map { |model_id| models_by_id[model_id] }
            .compact
            .find { |model| selectable_override_model?(model) }
        end

        def tenant_preferred_model
          model_id = subject.account.tenant_setting&.model_preference_for(create_pr_runner_key)
          return if model_id.blank?

          selectable_override_model(LlmModel.active.find_by(model_id: model_id))
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
          legacy_openrouter_runner_key?(model_preferences["preferred_agent_type"])
        end

        def create_pr_runner_openrouter?
          runner = create_pr_runner
          return legacy_openrouter_runner_key?(create_pr_runner_key) unless runner

          runner.openrouter_provider_routed?
        end

        def legacy_openrouter_runner_key?(value)
          %w[openrouter_free openrouter_pareto].include?(value)
        end

        # Health checks run without an AgentRun, so mirror the runtime
        # create_pr selection entry point on a duplicated settings record. This
        # keeps round-robin/random routing aligned with RunnerResolver without
        # mutating persisted selection state during a local check.
        def create_pr_runner_key
          create_pr_runner&.runner_key || create_pr_runner_identifier
        end

        def create_pr_runner_identifier
          @create_pr_runner_identifier ||= begin
            settings = AgentRuns::UserSettingsResolver.call(project: subject, strict: false)
            if settings.present?
              settings.dup.select_automated_runner_identifier(goal: "create_pr") ||
                settings.default_runner_identifier_for_goal("create_pr")
            end
          end
        end

        def create_pr_runner
          @create_pr_runner ||= begin
            identifier = create_pr_runner_identifier
            if identifier.present?
              owner = subject.effective_owner
              ::Runner.for_identifier(owner, identifier) if owner
            end
          end
        end

        def selectable_override_model(model)
          model if selectable_override_model?(model)
        end

        def selectable_override_model?(model)
          model && subject.llm_provider_allowed?(model.provider) && runner_compatible?(model)
        end

        def runner_compatible?(model)
          runner = create_pr_runner
          return true unless model && runner

          result = Runners::ModelCompatibility.call(
            runner_key: runner.runner_key,
            model_id: model.model_id,
            auth_type: runner.auth_type,
            provider_runtime: runner.agent_harness_runner_runtime(project: subject)
          )

          !result&.unsupported?
        end
      end
    end
  end
end
