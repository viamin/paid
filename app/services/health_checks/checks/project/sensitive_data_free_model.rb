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
          return [] if model.catalog_source == "openrouter_sync"

          finding(
            severity: :warning,
            message: "Sensitive project resolves to free model #{model.model_id} with possible training risk."
          )
        end

        private

        # Project-scope health checks do not have a runner/goal context, so
        # only deterministic project-level overrides are considered here.
        def resolved_model
          required_model || preferred_model
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

        def model_preferences
          @model_preferences ||= begin
            raw = subject.model_preferences
            raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
          end
        end

        def sensitive_project?
          subject.confidential? || subject.restricted?
        end
      end
    end
  end
end
