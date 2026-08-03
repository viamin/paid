# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class DeprecatedModel < HealthChecks::Check
        self.scope = :runner

        def self.network? = true

        def call
          resolved_models.filter_map do |tier, model|
            next unless deprecated_models_for(model.provider).include?(model.model_id)

            finding(
              severity: :warning,
              title: "Runner pinned to a deprecated model",
              description: "Runner #{runner_label} resolves to deprecated model #{model.model_id} at tier #{tier}.",
              remediation: "Update the runner's tier model mapping to a current model.",
              action_url: settings_action_url(:edit_runner_path),
              metadata: { runner_id: subject.id, model_id: model.model_id, tier: tier.to_s }
            ).first
          end
        end

        private

        def resolved_models
          LlmModel::TIERS.filter_map do |tier|
            resolution = Runners::ResolveTierModel.call(runner: subject, tier: tier, user: subject.user)
            next unless resolution.success?

            model = LlmModel.active.find_by(model_id: resolution.model_id)
            next unless model

            [ tier, model ]
          end
        end

        def deprecated_models_for(provider)
          deprecated_models_by_provider[provider] ||= drift_detector.deprecated_models_for(provider)
        end

        def deprecated_models_by_provider
          @deprecated_models_by_provider ||= {}
        end

        def drift_detector
          @drift_detector ||= Models::DetectCatalogDrift.new
        end

        def runner_label
          subject.name.presence || subject.runner_key
        end
      end
    end
  end
end
