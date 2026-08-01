# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class IncompatibleModel < HealthChecks::Check
        include ModelCheckSupport

        self.scope = :runner

        def self.network? = false

        def call
          LlmModel::TIERS.filter_map do |tier|
            incompatible_finding_for(tier)
          end
        end

        private

        def incompatible_finding_for(tier)
          result = resolved_tier_result(tier)
          return incompatible_resolution_finding(tier, result) if incompatible_resolution?(result)

          model = resolved_tier_model(tier)
          return unless model

          compatibility = compatibility_for(model.model_id)
          return unless compatibility&.unsupported?

          build_finding(
            severity: :error,
            message: "Runner #{subject.display_name} resolves incompatible model #{model.model_id} for #{tier} tier#{compatibility_suffix(compatibility)}."
          )
        end

        def incompatible_resolution?(result)
          result&.failure? && result.error&.include?("is not compatible with runner")
        end

        def incompatible_resolution_finding(tier, result)
          build_finding(
            severity: :error,
            message: "Runner #{subject.display_name} resolves incompatible model for #{tier} tier: #{result.error}."
          )
        end

        def compatibility_suffix(compatibility)
          compatibility.reason.present? ? " (#{compatibility.reason})" : nil
        end
      end
    end
  end
end
